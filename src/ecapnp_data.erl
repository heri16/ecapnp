%%
%%  Copyright 2013, Andreas Stenius <kaos@astekk.se>
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%

%% @copyright 2013, Andreas Stenius
%% @author Andreas Stenius <kaos@astekk.se>
%% @doc Data server module
%%
%% All objects data is held in a data process, implemented by this
%% module.

-module(ecapnp_data).
-author("Andreas Stenius <kaos@astekk.se>").
-behaviour(gen_server).

%% API
-export([start/1, start_link/1, stop/1, alloc/3, update_segment/3,
         get_segment/4, get_segment_size/2, get_segments/1, get_cap/2,
         get_cap_idx/2, get_cap_table/1, set_cap_table/2, add_ref/2,
         discard_ref/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ecapnp.hrl").

-define(DEFAULT_SEGMENT_SIZE, 100).

-record(seg, {
          id = 0 :: non_neg_integer(),
          usage = 0 :: non_neg_integer(),
          data = <<>> :: binary()
         }).

-record(state, {
          refs=[] :: list({pid(), reference()}),
          segments = [] :: list(#seg{}),
          caps = [] :: list({non_neg_integer(), #interface_ref{}})
         }).


%% ===================================================================
%% API functions
%% ===================================================================

start(Init) ->
    gen_server:start(?MODULE, {0, Init, self()}, []).

start_link(Init) ->
    gen_server:start_link(?MODULE, {0, Init, self()}, []).

stop(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, stop).

%% @doc Allocate data.
%%
%% Preferably from segment id `Id', if possible.  This will rarely
%% fail, as new segments are added in case there is not enough free
%% space left.
-spec alloc(segment_id(), integer(), pid()) -> {segment_id(), Offset::integer()}.
alloc(Id, Size, Pid)
  when is_integer(Id), is_integer(Size) ->
    data_request({alloc, {Id, Size}}, Pid).

%% @doc Write data to segment.
-spec update_segment({segment_id(), integer()}, binary(), pid()) -> ok.
update_segment({Id, Offset}, Data, Pid)
  when is_integer(Id), is_integer(Offset), is_binary(Data) ->
    data_request({update_segment, {Id, Offset, Data}}, Pid).

%% @doc Read data from segment.
-spec get_segment(segment_id(), integer(), integer(), pid()) -> binary().
get_segment(Id, Offset, Length, Pid)
  when is_integer(Id), is_integer(Offset) andalso
       is_integer(Length); Length == all ->
    data_request({get_segment, {Id, Offset, Length}}, Pid).

%% @doc Get size of segment, in words (8 bytes).
-spec get_segment_size(segment_id(), pid()) -> integer().
get_segment_size(Id, Pid) ->
    data_request({get_segment_size, Id}, Pid).

%% @doc Get all allocated data from all segments.
-spec get_segments(pid()) -> list(binary()).
get_segments(Pid) ->
    data_request(get_segments, Pid).

get_cap(Idx, Pid) ->
    data_request({get_cap, Idx}, Pid).

get_cap_idx(Cap, Pid) ->
    data_request({get_cap_idx, Cap}, Pid).

get_cap_table(Pid) ->
    data_request(get_cap_table, Pid).

set_cap_table(CapTable, Pid) ->
    data_request({set_cap_table, CapTable}, Pid).

add_ref(Ref, Pid) when is_pid(Ref) ->
    data_request({add_ref, Ref}, Pid).

discard_ref(Ref, Pid) when is_pid(Ref) ->
    data_request({discard_ref, Ref}, Pid).


%% ===================================================================
%% gen server callbacks
%% ===================================================================

init({Id, Init, Owner}) ->
    init_segments({Id, Init, init_state(Owner)}).

init_state(Owner) ->
    #state{ refs = [{Owner, monitor(process, Owner)}] }.

init_segments({Id, [S|Ss], State}) ->
    init_segments({Id + 1, Ss, set_segment(Id, new_segment(S), State)});
init_segments({_, [], State}) ->
    {ok, State};
init_segments({Id, Init, State}) ->
    {ok, set_segment(Id, new_segment(Init), State)}.

handle_call({alloc, {Id, Size}}, _From, State) ->
    {Reply, State1} = do_alloc(Id, Size, State),
    {reply, Reply, State1};
handle_call({get_segment, {Id, Offset, Length}}, _From, State) ->
    {Reply, State1} = do_get_segment(Id, Offset, Length, State),
    {reply, Reply, State1};
handle_call({get_segment_size, Id}, _From, State) ->
    {Reply, State1} = do_get_segment_size(Id, State),
    {reply, Reply, State1};
handle_call(get_segments, _From, State) ->
    {Reply, State1} = do_get_segments(State),
    {reply, Reply, State1};
handle_call({get_cap, Idx}, _From, State) ->
    {Reply, State1} = do_get_cap(Idx, State),
    {reply, Reply, State1};
handle_call({get_cap_idx, Cap}, _From, State) ->
    {Reply, State1} = do_get_cap_idx(Cap, State),
    {reply, Reply, State1};
handle_call(get_cap_table, _From, #state{ caps = CapTable }=State) ->
    {reply, {ok, CapTable}, State};
handle_call({set_cap_table, CapTable}, _From, #state{ caps = [] }=State) ->
    {reply, ok, State#state{ caps = CapTable }};
handle_call({add_ref, Ref}, _From, #state{ refs = Refs }=State) ->
    %% todo: should we also link to it.. ?
    {reply, ok, State#state{ refs = [{Ref, monitor(process, Ref)}|Refs] }};
handle_call({discard_ref, Ref}, _From, #state{ refs = Refs }=State) ->
    Refs1 = lists:keydelete(Ref, 1, Refs),
    State1 = State#state{ refs = Refs1 },
    if length(Refs1) == 0 -> {stop, normal, ok, State1};
       true -> {reply, ok, State1}
    end.

handle_cast({update_segment, {Id, Offset, Data}}, State) ->
    State1 = do_update_segment(Id, Offset, Data, State),
    {noreply, State1}.

handle_info({'DOWN', Ref, process, Pid, _Info}, #state{ refs = Refs }=State) ->
    %% todo: should we check for abnormal exits, and die along with it.. ?
    Refs1 = Refs -- [{Pid, Ref}],
    State1 = State#state{ refs = Refs1 },
    if length(Refs1) == 0 -> {stop, normal, State1};
       true -> {noreply, State1}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ===================================================================
%% internal functions
%% ===================================================================

data_request({update_segment, _}=R, Pid) when is_pid(Pid) ->
    gen_server:cast(Pid, R);
data_request(Request, Pid) when is_pid(Pid) ->
    gen_server:call(Pid, Request).

%% ===================================================================
do_alloc([Id|Ids], Size, State0) ->
    case do_alloc_data(Id, Size, State0) of
        {false, State} -> do_alloc(Ids, Size, State);
        Result -> Result
    end;
do_alloc([], Size, State) ->
    NextId = segment_count(State),
    do_alloc(
      [NextId|fail], Size,
      set_segment(NextId, new_segment(size_hint(Size)), State));
do_alloc(fail, _Size, State) ->
    {false, State};
do_alloc(Id, Size, State0) ->
    case do_alloc_data(Id, Size, State0) of
        {false, State} ->
            do_alloc(
              lists:seq(0, segment_count(State) - 1) -- [Id],
              Size + 1, State); %% add one for far ptr landing pad
        Result -> Result
    end.

do_alloc_data(Id, Size, State) ->
    case get_segment(Id, State) of
        #seg{ data = Data, usage = Usage }=S ->
            Alloc = Size * 8,
            if Alloc > (size(Data) - Usage) ->
                    {false, State};
               true ->
                    {{Id, Usage div 8},
                     set_segment(Id, S#seg{ usage = Usage + Alloc }, State)}
            end
    end.

%% ===================================================================
do_update_segment(Id, Offset, Data, State) ->
    Size = size(Data),
    case get_segment(Id, State) of
        #seg{
           data = <<Pre:Offset/binary-unit:64,
                    _:Size/binary,
                    Post/binary>>
          } = Seg ->
            set_segment(
              Id,
              Seg#seg{
                data = <<Pre/binary,
                         Data/binary,
                         Post/binary>>
               },
              State)
    end.

%% ===================================================================
do_get_segment(Id, Offset, all, State) ->
    #seg{ data =
              <<_:Offset/binary-unit:64,
                Segment/binary>>
        } = get_segment(Id, State),
    {Segment, State};
do_get_segment(Id, Offset, Length, State) ->
    #seg{ data = <<_:Offset/binary-unit:64,
                   Segment:Length/binary-unit:64,
                   _/binary>>
        } = get_segment(Id, State),
    {Segment, State}.

%% ===================================================================
do_get_segments(State) ->
    {[binary:part(S#seg.data, 0, S#seg.usage)
      || S <- State#state.segments], State}.

%% ===================================================================
do_get_segment_size(Id, State) ->
    case get_segment(Id, State) of
        #seg{ data = Segment } ->
            {size(Segment) div 8, State}
    end.

%% ===================================================================
do_get_cap(Idx, #state{ caps = CapTable }=State) when Idx < length(CapTable) ->
    {lists:nth(Idx + 1, CapTable), State};
do_get_cap(_, State) ->
    {undefined, State}.


%% ===================================================================
do_get_cap_idx(Cap, #state{ caps = CapTable }=State) ->
    case find_cap(Cap, CapTable, 0) of
        false ->
            Idx = length(CapTable),
            {Idx, State#state{ caps = CapTable ++ [Cap] }};
        Idx ->
            {Idx, State}
    end.

find_cap(_Cap, [], _Idx) -> false;
find_cap(Cap, [Cap|_], Idx) -> Idx;
find_cap(Cap, [_|Caps], Idx) -> find_cap(Cap, Caps, Idx + 1).

%% ===================================================================


%% ===================================================================
%% Data utils
%% ===================================================================

new_segment(Bin) when is_binary(Bin) ->
    #seg{ data = Bin, usage = size(Bin) };
new_segment(Size) when is_integer(Size), Size > 0 ->
    #seg{ data = <<0:Size/integer-unit:64>> };
new_segment(default) ->
    new_segment(?DEFAULT_SEGMENT_SIZE).

segment_count(#state{ segments = Ss }) ->
    length(Ss).

get_segment(Id, #state{ segments = Ss }) ->
    lists:keyfind(Id, #seg.id, Ss).

set_segment(Id, #seg{ id = Id }=S, #state{ segments = Ss }=State) ->
    State#state{
      segments = lists:keystore(Id, #seg.id, Ss, S)
     };
set_segment(Id, S, State) ->
    set_segment(Id, S#seg{ id = Id }, State).

size_hint(Size) when Size > ((?DEFAULT_SEGMENT_SIZE * ?DEFAULT_SEGMENT_SIZE) div 2) ->
    (1 + (Size div ?DEFAULT_SEGMENT_SIZE)) * ?DEFAULT_SEGMENT_SIZE;
size_hint(Size) ->
    size_hint(Size, ?DEFAULT_SEGMENT_SIZE).

size_hint(Size, Bucket) when Size > (Bucket div 2) ->
    size_hint(Size, 2 * Bucket);
size_hint(_Size, Bucket) -> Bucket.
