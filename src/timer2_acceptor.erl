%%%-------------------------------------------------------------------
%%% @author Mahesh Paolini-Subramanya <mahesh@dieswaytoofast.com>
%%% @copyright (C) 2011-2012 Juan Jose Comellas, Mahesh Paolini-Subramanya
%%% @doc High performance timer module
%%% @end
%%%
%%% This source file is subject to the New BSD License. You should have received
%%% a copy of the New BSD license with this software. If not, it can be
%%% retrieved from: http://www.opensource.org/licenses/bsd-license.php
%%%-------------------------------------------------------------------
-module(timer2_acceptor).

-author('Mahesh Paolini-Subramanya <mahesh@dieswaytoofast.com>').

% -compile([{parse_transform, lager_transform}]).

-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).
-export([delete/1]).

%% For debugging
-export([show_tables/0, match_send_interval/0, match_apply_interval/0, match_send_after/0, match_apply_after/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% Includes
%% ------------------------------------------------------------------

-include("defaults.hrl").

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link(?MODULE, [], []).

-spec delete(Timer2Ref) -> {'ok', 'delete'} | {'error', Reason} when
      Timer2Ref :: timer2_server_ref(),
      Reason :: term().

delete(Timer2Ref) ->
    process_request(delete, Timer2Ref).

show_tables() ->
    timer2_manager:safe_call({timer2_acceptor, undefined}, show_tables).

match_send_interval() ->
    timer2_manager:safe_call({timer2_acceptor, undefined}, match_send_interval).

match_apply_interval() ->
    timer2_manager:safe_call({timer2_acceptor, undefined}, match_apply_interval).

match_send_after() ->
    timer2_manager:safe_call({timer2_acceptor, undefined}, match_send_after).

match_apply_after() ->
    timer2_manager:safe_call({timer2_acceptor, undefined}, match_apply_after).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
    process_flag(trap_exit, true),
    AcceptorName = make_ref(),

    _ = timer2_manager:register_process(timer2_acceptor, AcceptorName),

    {ok, #state{}}.

handle_call({apply_after, Time, Args}, _From, State) ->
    Timer2Ref = timer2_manager:create_reference(),
    Message = {apply_after, Timer2Ref, Args},
    Reply = local_do_after(Timer2Ref, Time, Message, State),
    {reply, Reply, State};


handle_call({send_after, Time, Args}, _From, State) ->
    Timer2Ref = timer2_manager:create_reference(),
    Message = {send_after, Timer2Ref, Args},
    Reply = local_do_after(Timer2Ref, Time, Message, State),
    {reply, Reply, State};

handle_call({apply_interval, Time, {FromPid, _} = Args}, _From, State) ->
    Timer2Ref = timer2_manager:create_reference(),
    Message = {apply_interval, Timer2Ref, Time, Args},
    Reply = local_do_interval(FromPid, Timer2Ref, Time, Message, State),
    {reply, Reply, State};


handle_call({send_interval, Time, {FromPid, _} = Args}, _From, State) ->
    Timer2Ref = timer2_manager:create_reference(),
    Message = {send_interval, Timer2Ref, Time, Args},
    Reply = local_do_interval(FromPid, Timer2Ref, Time, Message, State),
    {reply, Reply, State};

handle_call({cancel, {_ETRef, Timer2Ref} = _Args}, _From, State) ->
    % Need to look up the TRef, because it might have changed due to *_interval usage
    Reply = case ets:lookup(?TIMER2_REF_TAB, Timer2Ref) of
        [{_, FinalTRef}] ->
            % follow the defination of http://erldocs.com/R15B/erts/erlang.html?i=0&search=timer#cancel_timer/1
            Time = erlang:cancel_timer(FinalTRef),
            _ = ets:delete(?TIMER2_TAB, FinalTRef),
            _ = ets:delete(?TIMER2_REF_TAB, Timer2Ref),
            Time;
        _ ->
            false
    end,
    {reply, Reply, State};

%
% Debugging
% 
handle_call(show_tables, _From, State) ->
    Timer2Tab = ets:tab2list(?TIMER2_TAB),
    Timer2RefTab = ets:tab2list(?TIMER2_REF_TAB),
    Timer2PidTab = ets:tab2list(?TIMER2_PID_TAB),
    {reply, {ok,{Timer2Tab,Timer2RefTab, Timer2PidTab}}, State};

handle_call(match_send_interval, _From, State) ->
    Timer2Match = ets:match(?TIMER2_TAB, {'_',{send_interval,'_','_','$1'}}),
    {reply, {ok,{Timer2Match}}, State};

handle_call(match_apply_interval, _From, State) ->
    Timer2Match = ets:match(?TIMER2_TAB, {'_',{apply_interval,'_','_','$1'}}),
    {reply, {ok,{Timer2Match}}, State};

handle_call(match_send_after, _From, State) ->
    Timer2Match = ets:match(?TIMER2_TAB, {'_',{send_after,'_',{'$1','_'}}}),
    {reply, {ok,{Timer2Match}}, State};

handle_call(match_apply_after, _From, State) ->
    Timer2Match = ets:match(?TIMER2_TAB, {'_',{apply_after,'_',{'$1','_'}}}),
    {reply, {ok,{Timer2Match}}, State};

handle_call(ping, _From, State) ->
    {reply, {ok, ping}, State};

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

%% Deletes always come from the processor.  
handle_cast({delete, Timer2Ref} = _Args, State) ->
    case ets:lookup(?TIMER2_REF_TAB, Timer2Ref) of
        [{_, OldETRef}] ->
            case ets:lookup(?TIMER2_TAB, OldETRef) of
                %% The delete might refer to an interval, in which case, redo the timer
                [{_, {apply_interval, Timer2Ref, Time, {FromPid, _}} = Message}] ->
                    local_do_interval(FromPid, Timer2Ref, Time, Message, State);
                [{_, {send_interval, Timer2Ref, Time, {FromPid, _}} = Message}] ->
                    local_do_interval(FromPid, Timer2Ref, Time, Message, State);
                %% The delete is for a oneshot, or bad data
                _Other ->
                    _ = ets:delete(?TIMER2_REF_TAB, Timer2Ref)
            end,
            %% Regardless, delete the original timer
            _ = ets:delete(?TIMER2_TAB, OldETRef);
        _Other ->
            ok
    end,
    {noreply, State};


handle_cast(_Msg, State) ->
    {noreply, State}.

% If one of the linked procs dies, cleanup all timers associated with it
handle_info({'EXIT',  Pid, _Reason}, State) -> 
    PidList = ets:lookup(?TIMER2_PID_TAB, Pid),
    lists:map(fun({_, Timer2Ref}) ->
                case ets:lookup(?TIMER2_REF_TAB, Timer2Ref) of
                    [{_, TRef}] ->
                        _ = erlang:cancel_timer(TRef),
                        _ = ets:delete(?TIMER2_TAB, TRef);
                    _ ->
                        ok
                end,
                _ = ets:delete(?TIMER2_REF_TAB, Timer2Ref)
        end, PidList),
    _ = ets:delete(?TIMER2_PID_TAB, Pid),
    {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec local_do_after(timer2_server_ref(), time(), any(), #state{}) ->
                               {ok, {reference(), timer2_server_ref()}} | error().
local_do_after(Timer2Ref, Time, Message, _State) ->
    case timer2_manager:get_process(timer2_processor) of
        Pid when is_pid(Pid) ->
            NewETRef =  erlang:start_timer(Time, Pid, Message),
            true = ets:insert(?TIMER2_REF_TAB, {Timer2Ref, NewETRef}),
            true = ets:insert(?TIMER2_TAB, {NewETRef, Message}),
            {ok, {NewETRef, Timer2Ref}};
        Error ->
            Error
    end.

-spec local_do_interval(pid(), timer2_server_ref(), time(), any(), #state{}) ->
                               {ok, {reference(), timer2_server_ref()}} | error().
local_do_interval(FromPid, Timer2Ref, Time, Message, _State) ->
    case timer2_manager:get_process(timer2_processor) of
        ToPid when is_pid(ToPid) ->
            ETRef = erlang:start_timer(Time, ToPid, Message),
            % Need to link to the FromPid so we can remove these entries
            try
                link(FromPid),
                true = ets:insert(?TIMER2_TAB, {ETRef, Message}),
                true = ets:insert(?TIMER2_REF_TAB, {Timer2Ref, ETRef}),
                true = ets:insert(?TIMER2_PID_TAB, {FromPid, Timer2Ref}),
                {ok, {ETRef, Timer2Ref}}
            catch _:Error ->
                    true = ets:delete(?TIMER2_TAB, {ETRef, Message}),
                    true = ets:delete(?TIMER2_REF_TAB, {Timer2Ref, ETRef}),
                    true = ets:delete(?TIMER2_PID_TAB, {FromPid, Timer2Ref}),
                    {error, Error}
            end;
        Error ->
            Error
    end.

process_request(delete, Timer2Ref) ->
    %% Could have this go through gproc, but why do so if not necessary?
    timer2_manager:safe_cast({timer2_acceptor, undefined}, {delete, Timer2Ref}).
