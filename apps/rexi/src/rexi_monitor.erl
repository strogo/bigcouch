% Copyright 2010 Cloudant
% 
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

-module(rexi_monitor).
-export([start/1, stop/1]).

-include_lib("eunit/include/eunit.hrl").

%% @doc spawn_links a process which monitors the supplied list of items and
%% returns the process ID.  If a monitored process exits, the caller will
%% receive a {rexi_DOWN, MonitoringPid, DeadPid, Reason} message.
-spec start([pid() | atom() | {atom(),node()}]) -> pid().
start(Procs) ->
    Parent = self(),
    spawn_link(fun() ->
        [erlang:monitor(process, P) || P <- Procs],
        wait_monitors(Parent)
    end).

%% @doc Cleanly shut down the monitoring process and flush all rexi_DOWN
%% messages from our mailbox.
-spec stop(pid()) -> ok.
stop(MonitoringPid) ->
    MonitoringPid ! {self(), shutdown},
    flush_down_messages().

%% internal functions %%

wait_monitors(Parent) ->
    receive
    {'DOWN', _, process, Pid, Reason} ->
        Parent ! {rexi_DOWN, self(), Pid, Reason},
        wait_monitors(Parent);
    {Parent, shutdown} ->
        ok
    end.

flush_down_messages() ->
    receive {rexi_DOWN, _, _, _} ->
        flush_down_messages()
    after 0 ->
        ok
    end.
