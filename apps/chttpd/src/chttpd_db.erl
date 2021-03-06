% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(chttpd_db).
-include_lib("couch/include/couch_db.hrl").

-export([handle_request/1, handle_compact_req/2, handle_design_req/2,
    db_req/2, couch_doc_open/4,handle_changes_req/2,
    update_doc_result_to_json/1, update_doc_result_to_json/2,
    handle_design_info_req/3, handle_view_cleanup_req/2]).

-import(chttpd,
    [send_json/2,send_json/3,send_json/4,send_method_not_allowed/2,
    start_json_response/2,send_chunk/2,end_json_response/1,
    start_chunked_response/3, absolute_uri/2, send/2,
    start_response_length/4]).

-record(doc_query_args, {
    options = [],
    rev = nil,
    open_revs = [],
    update_type = interactive_edit,
    atts_since = nil
}).

% Database request handlers
handle_request(#httpd{path_parts=[DbName|RestParts],method=Method,
        db_url_handlers=DbUrlHandlers}=Req)->
    case {Method, RestParts} of
    {'PUT', []} ->
        create_db_req(Req, DbName);
    {'DELETE', []} ->
        delete_db_req(Req, DbName);
    {_, []} ->
        do_db_req(Req, fun db_req/2);
    {_, [SecondPart|_]} ->
        Handler = couch_util:get_value(SecondPart, DbUrlHandlers, fun db_req/2),
        do_db_req(Req, Handler)
    end.

handle_changes_req(#httpd{method='GET'}=Req, Db) ->
    #changes_args{filter=Raw, style=Style} = Args0 = parse_changes_query(Req),
    ChangesArgs = Args0#changes_args{
        filter = couch_changes:make_filter_fun(Raw, Style, Req, Db)
    },
    case ChangesArgs#changes_args.feed of
    "normal" ->
        T0 = now(),
        {ok, Info} = fabric:get_db_info(Db),
        Etag = chttpd:make_etag(Info),
        DeltaT = timer:now_diff(now(), T0) / 1000,
        couch_stats_collector:record({couchdb, dbinfo}, DeltaT),
        chttpd:etag_respond(Req, Etag, fun() ->
            {ok, Resp} = chttpd:start_json_response(Req, 200, [{"Etag",Etag}]),
            fabric:changes(Db, fun changes_callback/2, {"normal", Resp},
                ChangesArgs)
        end);
    Feed ->
        % "longpoll" or "continuous"
        {ok, Resp} = chttpd:start_json_response(Req, 200),
        fabric:changes(Db, fun changes_callback/2, {Feed, Resp}, ChangesArgs)
    end;
handle_changes_req(#httpd{path_parts=[_,<<"_changes">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "GET,HEAD").

% callbacks for continuous feed (newline-delimited JSON Objects)
changes_callback(start, {"continuous", _} = Acc) ->
    {ok, Acc};
changes_callback({change, Change}, {"continuous", Resp} = Acc) ->
    send_chunk(Resp, [?JSON_ENCODE(Change) | "\n"]),
    {ok, Acc};
changes_callback({stop, EndSeq0}, {"continuous", Resp}) ->
    EndSeq = case is_old_couch(Resp) of true -> 0; false -> EndSeq0 end,
    send_chunk(Resp, [?JSON_ENCODE({[{<<"last_seq">>, EndSeq}]}) | "\n"]),
    end_json_response(Resp);

% callbacks for longpoll and normal (single JSON Object)
changes_callback(start, {_, Resp}) ->
    send_chunk(Resp, "{\"results\":[\n"),
    {ok, {"", Resp}};
changes_callback({change, Change}, {Prepend, Resp}) ->
    send_chunk(Resp, [Prepend, ?JSON_ENCODE(Change)]),
    {ok, {",\r\n", Resp}};
changes_callback({stop, EndSeq}, {_, Resp}) ->
    case is_old_couch(Resp) of
    true ->
        send_chunk(Resp, "\n],\n\"last_seq\":0}\n");
    false ->
        send_chunk(Resp, io_lib:format("\n],\n\"last_seq\":\"~s\"}\n",[EndSeq]))
    end,
    end_json_response(Resp);

changes_callback(timeout, {Prepend, Resp}) ->
    send_chunk(Resp, "\n"),
    {ok, {Prepend, Resp}};
changes_callback({error, Reason}, Resp) ->
    chttpd:send_chunked_error(Resp, {error, Reason}).

is_old_couch(Resp) ->
    MochiReq = Resp:get(request),
    case MochiReq:get_header_value("user-agent") of
    undefined ->
        false;
    UserAgent ->
        string:str(UserAgent, "CouchDB/0") > 0
    end.

handle_compact_req(Req, _) ->
    Msg = <<"Compaction must be triggered on a per-shard basis in BigCouch">>,
    couch_httpd:send_error(Req, 403, forbidden, Msg).

handle_view_cleanup_req(Req, Db) ->
    ok = fabric:cleanup_index_files(Db),
    send_json(Req, 202, {[{ok, true}]}).

handle_design_req(#httpd{
        path_parts=[_DbName, _Design, Name, <<"_",_/binary>> = Action | _Rest],
        design_url_handlers = DesignUrlHandlers
    }=Req, Db) ->
    case fabric:open_doc(Db, <<"_design/", Name/binary>>, []) of
    {ok, DDoc} ->
        % TODO we'll trigger a badarity here if ddoc attachment starts with "_",
        % or if user tries an unknown Action
        Handler = couch_util:get_value(Action, DesignUrlHandlers, fun db_req/2),
        Handler(Req, Db, DDoc);
    Error ->
        throw(Error)
    end;

handle_design_req(Req, Db) ->
    db_req(Req, Db).

handle_design_info_req(#httpd{method='GET'}=Req, Db, #doc{id=Id} = DDoc) ->
    {ok, GroupInfoList} = fabric:get_view_group_info(Db, DDoc),
    send_json(Req, 200, {[
        {name,  Id},
        {view_index, {GroupInfoList}}
    ]});

handle_design_info_req(Req, _Db, _DDoc) ->
    send_method_not_allowed(Req, "GET").

create_db_req(#httpd{user_ctx=UserCtx}=Req, DbName) ->
    N = couch_httpd:qs_value(Req, "n", couch_config:get("cluster", "n", "3")),
    Q = couch_httpd:qs_value(Req, "q", couch_config:get("cluster", "q", "8")),
    case fabric:create_db(DbName, [{user_ctx,UserCtx}, {n,N}, {q,Q}]) of
    ok ->
        DocUrl = absolute_uri(Req, "/" ++ couch_util:url_encode(DbName)),
        send_json(Req, 201, [{"Location", DocUrl}], {[{ok, true}]});
    {error, file_exists} ->
        chttpd:send_error(Req, file_exists);
    Error ->
        throw(Error)
    end.

delete_db_req(#httpd{user_ctx=UserCtx}=Req, DbName) ->
    case fabric:delete_db(DbName, [{user_ctx, UserCtx}]) of
    ok ->
        send_json(Req, 200, {[{ok, true}]});
    Error ->
        throw(Error)
    end.

do_db_req(#httpd{path_parts=[DbName|_]}=Req, Fun) ->
    Fun(Req, #db{name=DbName}).

db_req(#httpd{method='GET',path_parts=[DbName]}=Req, _Db) ->
    % measure the time required to generate the etag, see if it's worth it
    T0 = now(),
    {ok, DbInfo} = fabric:get_db_info(DbName),
    DeltaT = timer:now_diff(now(), T0) / 1000,
    couch_stats_collector:record({couchdb, dbinfo}, DeltaT),
    send_json(Req, {DbInfo});

db_req(#httpd{method='POST', path_parts=[DbName], user_ctx=Ctx}=Req, Db) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    Doc = couch_doc:from_json_obj(couch_httpd:json_body(Req)),
    Doc2 = case Doc#doc.id of
        <<"">> ->
            Doc#doc{id=couch_uuids:new(), revs={0, []}};
        _ ->
            Doc
    end,
    DocId = Doc2#doc.id,
    case couch_httpd:qs_value(Req, "batch") of
    "ok" ->
        % async_batching
        spawn(fun() ->
                case catch(fabric:update_doc(Db, Doc2, [{user_ctx, Ctx}])) of
                {ok, _} -> ok;
                Error ->
                    ?LOG_INFO("Batch doc error (~s): ~p",[DocId, Error])
                end
            end),

        send_json(Req, 202, [], {[
            {ok, true},
            {id, DocId}
        ]});
    _Normal ->
        % normal
        {ok, NewRev} = fabric:update_doc(Db, Doc2, [{user_ctx, Ctx}]),
        DocUrl = absolute_uri(Req, [$/, DbName, $/, DocId]),
        send_json(Req, 201, [{"Location", DocUrl}], {[
            {ok, true},
            {id, DocId},
            {rev, couch_doc:rev_to_str(NewRev)}
        ]})
    end;

db_req(#httpd{path_parts=[_DbName]}=Req, _Db) ->
    send_method_not_allowed(Req, "DELETE,GET,HEAD,POST");

db_req(#httpd{method='POST',path_parts=[_,<<"_ensure_full_commit">>]}=Req, _Db) ->
    send_json(Req, 201, {[
        {ok, true},
        {instance_start_time, <<"0">>}
    ]});

db_req(#httpd{path_parts=[_,<<"_ensure_full_commit">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "POST");

db_req(#httpd{method='POST',path_parts=[_,<<"_bulk_docs">>], user_ctx=Ctx}=Req, Db) ->
    couch_stats_collector:increment({httpd, bulk_requests}),
    couch_httpd:validate_ctype(Req, "application/json"),
    {JsonProps} = chttpd:json_body_obj(Req),
    DocsArray = couch_util:get_value(<<"docs">>, JsonProps),
    case chttpd:header_value(Req, "X-Couch-Full-Commit") of
    "true" ->
        Options = [full_commit, {user_ctx,Ctx}];
    "false" ->
        Options = [delay_commit, {user_ctx,Ctx}];
    _ ->
        Options = [{user_ctx,Ctx}]
    end,
    case couch_util:get_value(<<"new_edits">>, JsonProps, true) of
    true ->
        Docs = lists:map(
            fun({ObjProps} = JsonObj) ->
                Doc = couch_doc:from_json_obj(JsonObj),
                validate_attachment_names(Doc),
                Id = case Doc#doc.id of
                    <<>> -> couch_uuids:new();
                    Id0 -> Id0
                end,
                case couch_util:get_value(<<"_rev">>, ObjProps) of
                undefined ->
                    Revs = {0, []};
                Rev  ->
                    {Pos, RevId} = couch_doc:parse_rev(Rev),
                    Revs = {Pos, [RevId]}
                end,
                Doc#doc{id=Id,revs=Revs}
            end,
            DocsArray),
        Options2 =
        case couch_util:get_value(<<"all_or_nothing">>, JsonProps) of
        true  -> [all_or_nothing|Options];
        _ -> Options
        end,
        case fabric:update_docs(Db, Docs, Options2) of
        {ok, Results} ->
            % output the results
            DocResults = lists:zipwith(fun update_doc_result_to_json/2,
                Docs, Results),
            send_json(Req, 201, DocResults);
        {aborted, Errors} ->
            ErrorsJson =
                lists:map(fun update_doc_result_to_json/1, Errors),
            send_json(Req, 417, ErrorsJson)
        end;
    false ->
        Docs = [couch_doc:from_json_obj(JsonObj) || JsonObj <- DocsArray],
        [validate_attachment_names(D) || D <- Docs],
        {ok, Errors} = fabric:update_docs(Db, Docs, [replicated_changes|Options]),
        ErrorsJson = lists:map(fun update_doc_result_to_json/1, Errors),
        send_json(Req, 201, ErrorsJson)
    end;

db_req(#httpd{path_parts=[_,<<"_bulk_docs">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "POST");

db_req(#httpd{method='POST',path_parts=[_,<<"_purge">>]}=Req, Db) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    {IdsRevs} = chttpd:json_body_obj(Req),
    IdsRevs2 = [{Id, couch_doc:parse_revs(Revs)} || {Id, Revs} <- IdsRevs],
    case fabric:purge_docs(Db, IdsRevs2) of
    {ok, PurgeSeq, PurgedIdsRevs} ->
        PurgedIdsRevs2 = [{Id, couch_doc:revs_to_strs(Revs)} || {Id, Revs}
            <- PurgedIdsRevs],
        send_json(Req, 200, {[
            {<<"purge_seq">>, PurgeSeq},
            {<<"purged">>, {PurgedIdsRevs2}}
        ]});
    Error ->
        throw(Error)
    end;

db_req(#httpd{path_parts=[_,<<"_purge">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "POST");

db_req(#httpd{method='GET',path_parts=[_,<<"_all_docs">>]}=Req, Db) ->
    all_docs_view(Req, Db, nil);

db_req(#httpd{method='POST',path_parts=[_,<<"_all_docs">>]}=Req, Db) ->
    {Fields} = chttpd:json_body_obj(Req),
    case couch_util:get_value(<<"keys">>, Fields, nil) of
    Keys when is_list(Keys) ->
        all_docs_view(Req, Db, Keys);
    nil ->
        all_docs_view(Req, Db, nil);
    _ ->
        throw({bad_request, "`keys` body member must be an array."})
    end;

db_req(#httpd{path_parts=[_,<<"_all_docs">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "GET,HEAD,POST");

db_req(#httpd{method='POST',path_parts=[_,<<"_missing_revs">>]}=Req, Db) ->
    {JsonDocIdRevs} = couch_httpd:json_body_obj(Req),
    {ok, Results} = fabric:get_missing_revs(Db, JsonDocIdRevs),
    Results2 = [{Id, couch_doc:revs_to_strs(Revs)} || {Id, Revs} <- Results],
    send_json(Req, {[
        {missing_revs, {Results2}}
    ]});

db_req(#httpd{path_parts=[_,<<"_missing_revs">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "POST");

db_req(#httpd{method='POST',path_parts=[_,<<"_revs_diff">>]}=Req, Db) ->
    {JsonDocIdRevs} = couch_httpd:json_body_obj(Req),
    {ok, Results} = fabric:get_missing_revs(Db, JsonDocIdRevs),
    Results2 =
    lists:map(fun({Id, MissingRevs, PossibleAncestors}) ->
        {Id,
            {[{missing, couch_doc:revs_to_strs(MissingRevs)}] ++
                if PossibleAncestors == [] ->
                    [];
                true ->
                    [{possible_ancestors,
                        couch_doc:revs_to_strs(PossibleAncestors)}]
                end}}
    end, Results),
    send_json(Req, {Results2});

db_req(#httpd{path_parts=[_,<<"_revs_diff">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "POST");

db_req(#httpd{method='PUT',path_parts=[_,<<"_security">>],user_ctx=Ctx}=Req,
        Db) ->
    SecObj = couch_httpd:json_body(Req),
    ok = fabric:set_security(Db, SecObj, [{user_ctx,Ctx}]),
    send_json(Req, {[{<<"ok">>, true}]});

db_req(#httpd{method='GET',path_parts=[_,<<"_security">>]}=Req, Db) ->
    send_json(Req, fabric:get_security(Db));

db_req(#httpd{path_parts=[_,<<"_security">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "PUT,GET");

db_req(#httpd{method='PUT',path_parts=[_,<<"_revs_limit">>],user_ctx=Ctx}=Req,
        Db) ->
    Limit = chttpd:json_body(Req),
    ok = fabric:set_revs_limit(Db, Limit, [{user_ctx,Ctx}]),
    send_json(Req, {[{<<"ok">>, true}]});

db_req(#httpd{method='GET',path_parts=[_,<<"_revs_limit">>]}=Req, Db) ->
    send_json(Req, fabric:get_revs_limit(Db));

db_req(#httpd{path_parts=[_,<<"_revs_limit">>]}=Req, _Db) ->
    send_method_not_allowed(Req, "PUT,GET");

% vanilla CouchDB sends a 301 here, but we just handle the request
db_req(#httpd{path_parts=[DbName,<<"_design/",Name/binary>>|Rest]}=Req, Db) ->
    db_req(Req#httpd{path_parts=[DbName, <<"_design">>, Name | Rest]}, Db);

% Special case to enable using an unencoded slash in the URL of design docs,
% as slashes in document IDs must otherwise be URL encoded.
db_req(#httpd{path_parts=[_DbName,<<"_design">>,Name]}=Req, Db) ->
    db_doc_req(Req, Db, <<"_design/",Name/binary>>);

db_req(#httpd{path_parts=[_DbName,<<"_design">>,Name|FileNameParts]}=Req, Db) ->
    db_attachment_req(Req, Db, <<"_design/",Name/binary>>, FileNameParts);


% Special case to allow for accessing local documents without %2F
% encoding the docid. Throws out requests that don't have the second
% path part or that specify an attachment name.
db_req(#httpd{path_parts=[_DbName, <<"_local">>]}, _Db) ->
    throw({bad_request, <<"Invalid _local document id.">>});

db_req(#httpd{path_parts=[_DbName, <<"_local/">>]}, _Db) ->
    throw({bad_request, <<"Invalid _local document id.">>});

db_req(#httpd{path_parts=[_DbName, <<"_local">>, Name]}=Req, Db) ->
    db_doc_req(Req, Db, <<"_local/", Name/binary>>);

db_req(#httpd{path_parts=[_DbName, <<"_local">> | _Rest]}, _Db) ->
    throw({bad_request, <<"_local documents do not accept attachments.">>});

db_req(#httpd{path_parts=[_, DocId]}=Req, Db) ->
    db_doc_req(Req, Db, DocId);

db_req(#httpd{path_parts=[_, DocId | FileNameParts]}=Req, Db) ->
    db_attachment_req(Req, Db, DocId, FileNameParts).

all_docs_view(Req, Db, Keys) ->
    % measure the time required to generate the etag, see if it's worth it
    T0 = now(),
    {ok, Info} = fabric:get_db_info(Db),
    Etag = couch_httpd:make_etag(Info),
    DeltaT = timer:now_diff(now(), T0) / 1000,
    couch_stats_collector:record({couchdb, dbinfo}, DeltaT),
    QueryArgs = chttpd_view:parse_view_params(Req, Keys, map),
    chttpd:etag_respond(Req, Etag, fun() ->
        {ok, Resp} = chttpd:start_json_response(Req, 200, [{"Etag",Etag}]),
        fabric:all_docs(Db, fun all_docs_callback/2, {nil, Resp}, QueryArgs)
    end).

all_docs_callback({total_and_offset, Total, Offset}, {_, Resp}) ->
    Chunk = "{\"total_rows\":~p,\"offset\":~p,\"rows\":[\r\n",
    send_chunk(Resp, io_lib:format(Chunk, [Total, Offset])),
    {ok, {"", Resp}};
all_docs_callback({row, Row}, {Prepend, Resp}) ->
    send_chunk(Resp, [Prepend, ?JSON_ENCODE(Row)]),
    {ok, {",\r\n", Resp}};
all_docs_callback(complete, {_, Resp}) ->
    send_chunk(Resp, "\r\n]}"),
    end_json_response(Resp);
all_docs_callback({error, Reason}, {_, Resp}) ->
    chttpd:send_chunked_error(Resp, {error, Reason}).

db_doc_req(#httpd{method='DELETE'}=Req, Db, DocId) ->
    % check for the existence of the doc to handle the 404 case.
    couch_doc_open(Db, DocId, nil, []),
    case chttpd:qs_value(Req, "rev") of
    undefined ->
        Body = {[{<<"_deleted">>,true}]};
    Rev ->
        Body = {[{<<"_rev">>, ?l2b(Rev)},{<<"_deleted">>,true}]}
    end,
    update_doc(Req, Db, DocId, couch_doc_from_req(Req, DocId, Body));

db_doc_req(#httpd{method='GET'}=Req, Db, DocId) ->
    #doc_query_args{
        rev = Rev,
        open_revs = Revs,
        options = Options,
        atts_since = AttsSince
    } = parse_doc_query(Req),
    case Revs of
    [] ->
        Options2 =
        if AttsSince /= nil ->
            [{atts_since, AttsSince}, attachments | Options];
        true -> Options
        end,
        Doc = couch_doc_open(Db, DocId, Rev, Options2),
        send_doc(Req, Doc, Options2);
    _ ->
        {ok, Results} = fabric:open_revs(Db, DocId, Revs, Options),
        AcceptedTypes = case couch_httpd:header_value(Req, "Accept") of
            undefined       -> [];
            AcceptHeader    -> string:tokens(AcceptHeader, "; ")
        end,
        case lists:member("multipart/mixed", AcceptedTypes) of
        false ->
            {ok, Resp} = start_json_response(Req, 200),
            send_chunk(Resp, "["),
            % We loop through the docs. The first time through the separator
            % is whitespace, then a comma on subsequent iterations.
            lists:foldl(
                fun(Result, AccSeparator) ->
                    case Result of
                    {ok, Doc} ->
                        JsonDoc = couch_doc:to_json_obj(Doc, Options),
                        Json = ?JSON_ENCODE({[{ok, JsonDoc}]}),
                        send_chunk(Resp, AccSeparator ++ Json);
                    {{not_found, missing}, RevId} ->
                        RevStr = couch_doc:rev_to_str(RevId),
                        Json = ?JSON_ENCODE({[{"missing", RevStr}]}),
                        send_chunk(Resp, AccSeparator ++ Json)
                    end,
                    "," % AccSeparator now has a comma
                end,
                "", Results),
            send_chunk(Resp, "]"),
            end_json_response(Resp);
        true ->
            send_docs_multipart(Req, Results, Options)
        end
    end;

db_doc_req(#httpd{method='POST', user_ctx=Ctx}=Req, Db, DocId) ->
    couch_httpd:validate_referer(Req),
    couch_doc:validate_docid(DocId),
    couch_httpd:validate_ctype(Req, "multipart/form-data"),
    Form = couch_httpd:parse_form(Req),
    case proplists:is_defined("_doc", Form) of
    true ->
        Json = ?JSON_DECODE(couch_util:get_value("_doc", Form)),
        Doc = couch_doc_from_req(Req, DocId, Json);
    false ->
        Rev = couch_doc:parse_rev(list_to_binary(couch_util:get_value("_rev", Form))),
        {ok, [{ok, Doc}]} = fabric:open_revs(Db, DocId, [Rev], [])
    end,
    UpdatedAtts = [
        #att{name=validate_attachment_name(Name),
            type=list_to_binary(ContentType),
            data=Content} ||
        {Name, {ContentType, _}, Content} <-
        proplists:get_all_values("_attachments", Form)
    ],
    #doc{atts=OldAtts} = Doc,
    OldAtts2 = lists:flatmap(
        fun(#att{name=OldName}=Att) ->
            case [1 || A <- UpdatedAtts, A#att.name == OldName] of
            [] -> [Att]; % the attachment wasn't in the UpdatedAtts, return it
            _ -> [] % the attachment was in the UpdatedAtts, drop it
            end
        end, OldAtts),
    NewDoc = Doc#doc{
        atts = UpdatedAtts ++ OldAtts2
    },
    {ok, NewRev} = fabric:update_doc(Db, NewDoc, [{user_ctx,Ctx}]),

    send_json(Req, 201, [{"Etag", "\"" ++ ?b2l(couch_doc:rev_to_str(NewRev)) ++ "\""}], {[
        {ok, true},
        {id, DocId},
        {rev, couch_doc:rev_to_str(NewRev)}
    ]});

db_doc_req(#httpd{method='PUT', user_ctx=Ctx}=Req, Db, DocId) ->
    #doc_query_args{
        update_type = UpdateType
    } = parse_doc_query(Req),
    couch_doc:validate_docid(DocId),

    W = couch_httpd:qs_value(Req, "w", couch_config:get("cluster", "w", "2")),
    Options = [{user_ctx,Ctx}, {w,W}],

    Loc = absolute_uri(Req, [$/, Db#db.name, $/, DocId]),
    RespHeaders = [{"Location", Loc}],
    case couch_util:to_list(couch_httpd:header_value(Req, "Content-Type")) of
    ("multipart/related;" ++ _) = ContentType ->
        {ok, Doc0} = couch_doc:doc_from_multi_part_stream(ContentType,
                fun() -> receive_request_data(Req) end),
        Doc = couch_doc_from_req(Req, DocId, Doc0),
        update_doc(Req, Db, DocId, Doc, RespHeaders, UpdateType);
    _Else ->
        case couch_httpd:qs_value(Req, "batch") of
        "ok" ->
            % batch
            Doc = couch_doc_from_req(Req, DocId, couch_httpd:json_body(Req)),

            spawn(fun() ->
                    case catch(fabric:update_doc(Db, Doc, Options)) of
                    {ok, _} -> ok;
                    Error ->
                        ?LOG_INFO("Batch doc error (~s): ~p",[DocId, Error])
                    end
                end),
            send_json(Req, 202, [], {[
                {ok, true},
                {id, DocId}
            ]});
        _Normal ->
            % normal
            Body = couch_httpd:json_body(Req),
            Doc = couch_doc_from_req(Req, DocId, Body),
            update_doc(Req, Db, DocId, Doc, RespHeaders, UpdateType)
        end
    end;

db_doc_req(#httpd{method='COPY', user_ctx=Ctx}=Req, Db, SourceDocId) ->
    SourceRev =
    case extract_header_rev(Req, couch_httpd:qs_value(Req, "rev")) of
        missing_rev -> nil;
        Rev -> Rev
    end,
    {TargetDocId, TargetRevs} = parse_copy_destination_header(Req),
    % open old doc
    Doc = couch_doc_open(Db, SourceDocId, SourceRev, []),
    % save new doc
    {ok, NewTargetRev} = fabric:update_doc(Db,
        Doc#doc{id=TargetDocId, revs=TargetRevs}, [{user_ctx,Ctx}]),
    % respond
    send_json(Req, 201,
        [{"Etag", "\"" ++ ?b2l(couch_doc:rev_to_str(NewTargetRev)) ++ "\""}],
        update_doc_result_to_json(TargetDocId, {ok, NewTargetRev}));

db_doc_req(Req, _Db, _DocId) ->
    send_method_not_allowed(Req, "DELETE,GET,HEAD,POST,PUT,COPY").

send_doc(Req, Doc, Options) ->
    case Doc#doc.meta of
    [] ->
        DiskEtag = couch_httpd:doc_etag(Doc),
        % output etag only when we have no meta
        couch_httpd:etag_respond(Req, DiskEtag, fun() ->
            send_doc_efficiently(Req, Doc, [{"Etag", DiskEtag}], Options)
        end);
    _ ->
        send_doc_efficiently(Req, Doc, [], Options)
    end.

send_doc_efficiently(Req, #doc{atts=[]}=Doc, Headers, Options) ->
        send_json(Req, 200, Headers, couch_doc:to_json_obj(Doc, Options));
send_doc_efficiently(Req, #doc{atts=Atts}=Doc, Headers, Options) ->
    case lists:member(attachments, Options) of
    true ->
        AcceptedTypes = case couch_httpd:header_value(Req, "Accept") of
            undefined       -> [];
            AcceptHeader    -> string:tokens(AcceptHeader, ", ")
        end,
        case lists:member("multipart/related", AcceptedTypes) of
        false ->
            send_json(Req, 200, Headers, couch_doc:to_json_obj(Doc, Options));
        true ->
            Boundary = couch_uuids:random(),
            JsonBytes = ?JSON_ENCODE(couch_doc:to_json_obj(Doc,
                    [attachments, follows|Options])),
            {ContentType, Len} = couch_doc:len_doc_to_multi_part_stream(
                    Boundary,JsonBytes, Atts,false),
            CType = {<<"Content-Type">>, ContentType},
            {ok, Resp} = start_response_length(Req, 200, [CType|Headers], Len),
            couch_doc:doc_to_multi_part_stream(Boundary,JsonBytes,Atts,
                    fun(Data) -> couch_httpd:send(Resp, Data) end, false)
        end;
    false ->
        send_json(Req, 200, Headers, couch_doc:to_json_obj(Doc, Options))
    end.

send_docs_multipart(Req, Results, Options) ->
    OuterBoundary = couch_uuids:random(),
    InnerBoundary = couch_uuids:random(),
    CType = {"Content-Type",
        "multipart/mixed; boundary=\"" ++ ?b2l(OuterBoundary) ++ "\""},
    {ok, Resp} = start_chunked_response(Req, 200, [CType]),
    couch_httpd:send_chunk(Resp, <<"--", OuterBoundary/binary>>),
    lists:foreach(
        fun({ok, #doc{atts=Atts}=Doc}) ->
            JsonBytes = ?JSON_ENCODE(couch_doc:to_json_obj(Doc,
                    [attachments,follows|Options])),
            {ContentType, _Len} = couch_doc:len_doc_to_multi_part_stream(
                    InnerBoundary, JsonBytes, Atts, false),
            couch_httpd:send_chunk(Resp, <<"\r\nContent-Type: ",
                    ContentType/binary, "\r\n\r\n">>),
            couch_doc:doc_to_multi_part_stream(InnerBoundary, JsonBytes, Atts,
                    fun(Data) -> couch_httpd:send_chunk(Resp, Data)
                    end, false),
             couch_httpd:send_chunk(Resp, <<"\r\n--", OuterBoundary/binary>>);
        ({{not_found, missing}, RevId}) ->
             RevStr = couch_doc:rev_to_str(RevId),
             Json = ?JSON_ENCODE({[{"missing", RevStr}]}),
             couch_httpd:send_chunk(Resp,
                [<<"\r\nContent-Type: application/json; error=\"true\"\r\n\r\n">>,
                Json,
                <<"\r\n--", OuterBoundary/binary>>])
         end, Results),
    couch_httpd:send_chunk(Resp, <<"--">>),
    couch_httpd:last_chunk(Resp).

receive_request_data(Req) ->
    {couch_httpd:recv(Req, 0), fun() -> receive_request_data(Req) end}.

update_doc_result_to_json({{Id, Rev}, Error}) ->
        {_Code, Err, Msg} = chttpd:error_info(Error),
        {[{id, Id}, {rev, couch_doc:rev_to_str(Rev)},
            {error, Err}, {reason, Msg}]}.

update_doc_result_to_json(#doc{id=DocId}, Result) ->
    update_doc_result_to_json(DocId, Result);
update_doc_result_to_json(DocId, {ok, NewRev}) ->
    {[{id, DocId}, {rev, couch_doc:rev_to_str(NewRev)}]};
update_doc_result_to_json(DocId, Error) ->
    {_Code, ErrorStr, Reason} = chttpd:error_info(Error),
    {[{id, DocId}, {error, ErrorStr}, {reason, Reason}]}.


update_doc(Req, Db, DocId, Json) ->
    update_doc(Req, Db, DocId, Json, []).

update_doc(Req, Db, DocId, Doc, Headers) ->
    update_doc(Req, Db, DocId, Doc, Headers, interactive_edit).

update_doc(#httpd{user_ctx=Ctx} = Req, Db, DocId, #doc{deleted=Deleted}=Doc,
        Headers, UpdateType) ->
    W = couch_httpd:qs_value(Req, "w", couch_config:get("cluster", "w", "2")),
    case couch_httpd:header_value(Req, "X-Couch-Full-Commit") of
    "true" ->
        Options = [full_commit, UpdateType, {user_ctx,Ctx}, {w,W}];
    "false" ->
        Options = [delay_commit, UpdateType, {user_ctx,Ctx}, {w,W}];
    _ ->
        Options = [UpdateType, {user_ctx,Ctx}, {w,W}]
    end,
    {ok, NewRev} = fabric:update_doc(Db, Doc, Options),
    NewRevStr = couch_doc:rev_to_str(NewRev),
    ResponseHeaders = [{"Etag", <<"\"", NewRevStr/binary, "\"">>} | Headers],
    send_json(Req, if Deleted -> 200; true -> 201 end, ResponseHeaders, {[
        {ok, true},
        {id, DocId},
        {rev, NewRevStr}
    ]}).

couch_doc_from_req(Req, DocId, #doc{revs=Revs} = Doc) ->
    validate_attachment_names(Doc),
    ExplicitDocRev =
    case Revs of
        {Start,[RevId|_]} -> {Start, RevId};
        _ -> undefined
    end,
    case extract_header_rev(Req, ExplicitDocRev) of
    missing_rev ->
        Revs2 = {0, []};
    ExplicitDocRev ->
        Revs2 = Revs;
    {Pos, Rev} ->
        Revs2 = {Pos, [Rev]}
    end,
    Doc#doc{id=DocId, revs=Revs2};
couch_doc_from_req(Req, DocId, Json) ->
    couch_doc_from_req(Req, DocId, couch_doc:from_json_obj(Json)).


% Useful for debugging
% couch_doc_open(Db, DocId) ->
%   couch_doc_open(Db, DocId, nil, []).

couch_doc_open(Db, DocId, Rev, Options) ->
    case Rev of
    nil -> % open most recent rev
        case fabric:open_doc(Db, DocId, Options) of
        {ok, Doc} ->
            Doc;
         Error ->
             throw(Error)
         end;
  _ -> % open a specific rev (deletions come back as stubs)
      case fabric:open_revs(Db, DocId, [Rev], Options) of
          {ok, [{ok, Doc}]} ->
              Doc;
          {ok, [{{not_found, missing}, Rev}]} ->
              throw(not_found);
          {ok, [Else]} ->
              throw(Else)
      end
  end.

% Attachment request handlers

db_attachment_req(#httpd{method='GET'}=Req, Db, DocId, FileNameParts) ->
    FileName = list_to_binary(mochiweb_util:join(lists:map(fun binary_to_list/1,
        FileNameParts),"/")),
    #doc_query_args{
        rev=Rev,
        options=Options
    } = parse_doc_query(Req),
    #doc{
        atts=Atts
    } = Doc = couch_doc_open(Db, DocId, Rev, Options),
    case [A || A <- Atts, A#att.name == FileName] of
    [] ->
        throw({not_found, "Document is missing attachment"});
    [#att{type=Type, encoding=Enc, disk_len=DiskLen, att_len=AttLen}=Att] ->
        Etag = chttpd:doc_etag(Doc),
        ReqAcceptsAttEnc = lists:member(
           atom_to_list(Enc),
           couch_httpd:accepted_encodings(Req)
        ),
        Headers = [
            {"ETag", Etag},
            {"Cache-Control", "must-revalidate"},
            {"Content-Type", binary_to_list(Type)}
        ] ++ case ReqAcceptsAttEnc of
        true ->
            [{"Content-Encoding", atom_to_list(Enc)}];
        _ ->
            []
        end,
        Len = case {Enc, ReqAcceptsAttEnc} of
        {identity, _} ->
            % stored and served in identity form
            DiskLen;
        {_, false} when DiskLen =/= AttLen ->
            % Stored encoded, but client doesn't accept the encoding we used,
            % so we need to decode on the fly.  DiskLen is the identity length
            % of the attachment.
            DiskLen;
        {_, true} ->
            % Stored and served encoded.  AttLen is the encoded length.
            AttLen;
        _ ->
            % We received an encoded attachment and stored it as such, so we
            % don't know the identity length.  The client doesn't accept the
            % encoding, and since we cannot serve a correct Content-Length
            % header we'll fall back to a chunked response.
            undefined
        end,
        AttFun = case ReqAcceptsAttEnc of
        false ->
            fun couch_doc:att_foldl_decode/3;
        true ->
            fun couch_doc:att_foldl/3
        end,
        couch_httpd:etag_respond(
            Req,
            Etag,
            fun() ->
                case Len of
                undefined ->
                    {ok, Resp} = start_chunked_response(Req, 200, Headers),
                    AttFun(Att, fun(Seg, _) -> send_chunk(Resp, Seg) end, ok),
                    couch_httpd:last_chunk(Resp);
                _ ->
                    {ok, Resp} = start_response_length(Req, 200, Headers, Len),
                    AttFun(Att, fun(Seg, _) -> send(Resp, Seg) end, ok)
                end
            end
        )
    end;


db_attachment_req(#httpd{method=Method, user_ctx=Ctx}=Req, Db, DocId, FileNameParts)
        when (Method == 'PUT') or (Method == 'DELETE') ->
    FileName = validate_attachment_name(
                    mochiweb_util:join(
                        lists:map(fun binary_to_list/1,
                            FileNameParts),"/")),

    NewAtt = case Method of
        'DELETE' ->
            [];
        _ ->
            [#att{
                name=FileName,
                type = case couch_httpd:header_value(Req,"Content-Type") of
                    undefined ->
                        % We could throw an error here or guess by the FileName.
                        % Currently, just giving it a default.
                        <<"application/octet-stream">>;
                    CType ->
                        list_to_binary(CType)
                    end,
                data = fabric:att_receiver(Req, chttpd:body_length(Req)),
                att_len = case couch_httpd:header_value(Req,"Content-Length") of
                    undefined ->
                        undefined;
                    Length ->
                        list_to_integer(Length)
                    end,
                md5 = get_md5_header(Req),
                encoding = case string:to_lower(string:strip(
                    couch_httpd:header_value(Req,"Content-Encoding","identity")
                )) of
                "identity" ->
                   identity;
                "gzip" ->
                   gzip;
                _ ->
                   throw({
                       bad_ctype,
                       "Only gzip and identity content-encodings are supported"
                   })
                end
            }]
    end,

    Doc = case extract_header_rev(Req, couch_httpd:qs_value(Req, "rev")) of
        missing_rev -> % make the new doc
            couch_doc:validate_docid(DocId),
            #doc{id=DocId};
        Rev ->
            case fabric:open_revs(Db, DocId, [Rev], []) of
            {ok, [{ok, Doc0}]}  -> Doc0;
            {ok, [Error]}       -> throw(Error)
            end
    end,

    #doc{atts=Atts} = Doc,
    DocEdited = Doc#doc{
        atts = NewAtt ++ [A || A <- Atts, A#att.name /= FileName]
    },
    {ok, UpdatedRev} = fabric:update_doc(Db, DocEdited, [{user_ctx,Ctx}]),
    #db{name=DbName} = Db,

    {Status, Headers} = case Method of
        'DELETE' ->
            {200, []};
        _ ->
            {201, [{"Location", absolute_uri(Req, [$/, DbName, $/, DocId, $/,
                FileName])}]}
        end,
    send_json(Req,Status, Headers, {[
        {ok, true},
        {id, DocId},
        {rev, couch_doc:rev_to_str(UpdatedRev)}
    ]});

db_attachment_req(Req, _Db, _DocId, _FileNameParts) ->
    send_method_not_allowed(Req, "DELETE,GET,HEAD,PUT").

get_md5_header(Req) ->
    ContentMD5 = couch_httpd:header_value(Req, "Content-MD5"),
    Length = couch_httpd:body_length(Req),
    Trailer = couch_httpd:header_value(Req, "Trailer"),
    case {ContentMD5, Length, Trailer} of
        _ when is_list(ContentMD5) orelse is_binary(ContentMD5) ->
            base64:decode(ContentMD5);
        {_, chunked, undefined} ->
            <<>>;
        {_, chunked, _} ->
            case re:run(Trailer, "\\bContent-MD5\\b", [caseless]) of
                {match, _} ->
                    md5_in_footer;
                _ ->
                    <<>>
            end;
        _ ->
            <<>>
    end.

parse_doc_query(Req) ->
    lists:foldl(fun({Key,Value}, Args) ->
        case {Key, Value} of
        {"attachments", "true"} ->
            Options = [attachments | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"meta", "true"} ->
            Options = [revs_info, conflicts, deleted_conflicts | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"revs", "true"} ->
            Options = [revs | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"local_seq", "true"} ->
            Options = [local_seq | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"revs_info", "true"} ->
            Options = [revs_info | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"conflicts", "true"} ->
            Options = [conflicts | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"deleted_conflicts", "true"} ->
            Options = [deleted_conflicts | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"rev", Rev} ->
            Args#doc_query_args{rev=couch_doc:parse_rev(Rev)};
        {"open_revs", "all"} ->
            Args#doc_query_args{open_revs=all};
        {"open_revs", RevsJsonStr} ->
            JsonArray = ?JSON_DECODE(RevsJsonStr),
            Args#doc_query_args{open_revs=[couch_doc:parse_rev(Rev) || Rev <- JsonArray]};
        {"atts_since", RevsJsonStr} ->
            JsonArray = ?JSON_DECODE(RevsJsonStr),
            Args#doc_query_args{atts_since = couch_doc:parse_revs(JsonArray)};
        {"new_edits", "false"} ->
            Args#doc_query_args{update_type=replicated_changes};
        {"new_edits", "true"} ->
            Args#doc_query_args{update_type=interactive_edit};
        {"att_encoding_info", "true"} ->
            Options = [att_encoding_info | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"r", R} ->
            Options = [{r,R} | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        {"w", W} ->
            Options = [{w,W} | Args#doc_query_args.options],
            Args#doc_query_args{options=Options};
        _Else -> % unknown key value pair, ignore.
            Args
        end
    end, #doc_query_args{}, chttpd:qs(Req)).

parse_changes_query(Req) ->
    lists:foldl(fun({Key, Value}, Args) ->
        case {Key, Value} of
        {"feed", _} ->
            Args#changes_args{feed=Value};
        {"descending", "true"} ->
            Args#changes_args{dir=rev};
        {"since", _} ->
            Args#changes_args{since=Value};
        {"limit", _} ->
            Args#changes_args{limit=list_to_integer(Value)};
        {"style", _} ->
            Args#changes_args{style=list_to_existing_atom(Value)};
        {"heartbeat", "true"} ->
            Args#changes_args{heartbeat=true};
        {"heartbeat", _} ->
            Args#changes_args{heartbeat=list_to_integer(Value)};
        {"timeout", _} ->
            Args#changes_args{timeout=list_to_integer(Value)};
        {"include_docs", "true"} ->
            Args#changes_args{include_docs=true};
        {"filter", _} ->
            Args#changes_args{filter=Value};
        _Else -> % unknown key value pair, ignore.
            Args
        end
    end, #changes_args{}, couch_httpd:qs(Req)).

extract_header_rev(Req, ExplicitRev) when is_binary(ExplicitRev) or is_list(ExplicitRev)->
    extract_header_rev(Req, couch_doc:parse_rev(ExplicitRev));
extract_header_rev(Req, ExplicitRev) ->
    Etag = case chttpd:header_value(Req, "If-Match") of
        undefined -> undefined;
        Value -> couch_doc:parse_rev(string:strip(Value, both, $"))
    end,
    case {ExplicitRev, Etag} of
    {undefined, undefined} -> missing_rev;
    {_, undefined} -> ExplicitRev;
    {undefined, _} -> Etag;
    _ when ExplicitRev == Etag -> Etag;
    _ ->
        throw({bad_request, "Document rev and etag have different values"})
    end.


parse_copy_destination_header(Req) ->
    Destination = chttpd:header_value(Req, "Destination"),
    case re:run(Destination, "\\?", [{capture, none}]) of
    nomatch ->
        {list_to_binary(Destination), {0, []}};
    match ->
        [DocId, RevQs] = re:split(Destination, "\\?", [{return, list}]),
        [_RevQueryKey, Rev] = re:split(RevQs, "=", [{return, list}]),
        {Pos, RevId} = couch_doc:parse_rev(Rev),
        {list_to_binary(DocId), {Pos, [RevId]}}
    end.

validate_attachment_names(Doc) ->
    lists:foreach(fun(#att{name=Name}) ->
        validate_attachment_name(Name)
    end, Doc#doc.atts).

validate_attachment_name(Name) when is_list(Name) ->
    validate_attachment_name(list_to_binary(Name));
validate_attachment_name(<<"_",_/binary>>) ->
    throw({bad_request, <<"Attachment name can't start with '_'">>});
validate_attachment_name(Name) ->
    case is_valid_utf8(Name) of
        true -> Name;
        false -> throw({bad_request, <<"Attachment name is not UTF-8 encoded">>})
    end.

%% borrowed from mochijson2:json_bin_is_safe()
is_valid_utf8(<<>>) ->
    true;
is_valid_utf8(<<C, Rest/binary>>) ->
    case C of
        $\" ->
            false;
        $\\ ->
            false;
        $\b ->
            false;
        $\f ->
            false;
        $\n ->
            false;
        $\r ->
            false;
        $\t ->
            false;
        C when C >= 0, C < $\s; C >= 16#7f, C =< 16#10FFFF ->
            false;
        C when C < 16#7f ->
            is_valid_utf8(Rest);
        _ ->
            false
    end.
