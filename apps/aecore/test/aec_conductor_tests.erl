%%%=============================================================================
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc
%%%   Unit tests for the aec_miner
%%% @end
%%%=============================================================================
-module(aec_conductor_tests).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-include("common.hrl").
-include("blocks.hrl").
-include("txs.hrl").

-define(TEST_MODULE, aec_conductor).

setup_common() ->
    meck:new(application, [unstick, passthrough]),
    aec_test_utils:mock_fast_cuckoo_pow(),
    ok = application:ensure_started(erlexec),
    ok = application:ensure_started(gproc),
    meck:new(aec_governance, [passthrough]),
    meck:expect(aec_governance, expected_block_mine_rate,
                fun() ->
                        meck:passthrough([]) div 2560
                end),
    TmpKeysDir = aec_test_utils:aec_keys_setup(),
    aec_test_utils:mock_time(),
    {ok, _} = aec_tx_pool:start_link(),
    {ok, _} = aec_persistence:start_link(),
    TmpKeysDir.

teardown_common(TmpKeysDir) ->
    ok = ?TEST_MODULE:stop(),
    ok = aec_persistence:stop_and_clean(),
    ok = aec_tx_pool:stop(),
    ok = application:stop(gproc),
    _  = flush_gproc(),
    ?assert(meck:validate(aec_governance)),
    meck:unload(aec_governance),
    aec_test_utils:unmock_time(),
    aec_test_utils:aec_keys_cleanup(TmpKeysDir),
    meck:unload(application),
    ok.

%%%===================================================================
%%% Tests for mining infrastructure
%%%===================================================================

miner_test_() ->
    {foreach,
     fun() ->
             TmpKeysDir = setup_common(),
             {ok, _} = ?TEST_MODULE:start_link([{autostart, true}]),
             TmpKeysDir
     end,
     fun(TmpKeysDir) ->
             teardown_common(TmpKeysDir)
     end,
     [{"Stop and restart miner", fun test_stop_restart/0},
      {"Test consequtive start/stop ", fun test_stop_restart_seq/0},
      {"Run miner for a while", fun test_run_miner/0}
     ]}.

test_stop_restart() ->
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    ?assertEqual(ok, ?TEST_MODULE:start_mining()),
    wait_for_running(),
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    ?assertEqual(ok, ?TEST_MODULE:start_mining()),
    wait_for_running(),
    ok.

test_stop_restart_seq() ->
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    ?assertEqual(ok, ?TEST_MODULE:start_mining()),
    wait_for_running(),
    ?assertEqual(ok, ?TEST_MODULE:start_mining()),
    wait_for_running(),
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    ok.

test_run_miner() ->
    ?assertEqual(0, get_top_height()),
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    wait_for_stopped(),
    true = aec_events:subscribe(block_created),
    ?assertEqual(ok, ?TEST_MODULE:start_mining()),
    wait_for_block_created(),
    ?assert(0 < get_top_height()),
    ?assertEqual(ok, ?TEST_MODULE:stop_mining()),
    ok.

%%%===================================================================
%%% Chain tests
%%%===================================================================

chain_test_() ->
    {foreach,
     fun() ->
             TmpKeysDir = setup_common(),
             {ok, _} = ?TEST_MODULE:start_link(),
             meck:new(aec_headers, [passthrough]),
             meck:new(aec_blocks, [passthrough]),
             meck:expect(aec_headers, validate, fun(_) -> ok end),
             meck:expect(aec_blocks, validate, fun(_) -> ok end),
             TmpKeysDir
     end,
     fun(TmpKeysDir) ->
             teardown_common(TmpKeysDir),
             meck:unload(aec_headers),
             meck:unload(aec_blocks),
             ok
     end,
     [
      {"Start mining add a block.", fun test_start_mining_add_block/0},
      {"Test preemption of mining", fun test_preemption/0},
      {"Test chain api"           , fun test_chain_api/0},
      {"Test block publishing"    , fun test_block_publishing/0}
     ]}.

test_start_mining_add_block() ->
    %% Add a couple of blocks to the chain.
    [_GB, B1, B2] = aec_test_utils:gen_block_chain(3),
    BH2 = aec_blocks:to_header(B2),
    ?assertEqual(ok, ?TEST_MODULE:post_block(B1)),
    ?assertEqual(ok, ?TEST_MODULE:post_block(B2)),
    aec_test_utils:wait_for_it(
      fun () -> aec_conductor:top_header() end,
      BH2).

test_preemption() ->
    %% Stop the miner to be in a controlled environment
    aec_conductor:stop_mining(),
    wait_for_stopped(),

    %% Generate a chain
    Chain = aec_test_utils:gen_block_chain(7),
    {Chain1, Chain2} = lists:split(3, Chain),
    Top1 = lists:last(Chain1),
    Top2 = lists:last(Chain2),
    Hash1 = block_hash(Top1),
    Hash2 = block_hash(Top2),

    %% Seed the server with the first part of the chain
    [ok = ?TEST_MODULE:post_block(B) || B <- Chain1],
    wait_for_top_block_hash(Hash1),

    %% Start mining and make sure we are starting
    %% from the correct hash.
    true = aec_events:subscribe(start_mining),
    aec_conductor:start_mining(),

    wait_for_start_mining(Hash1),

    %% Post the rest of the chain, which will take over.
    [?TEST_MODULE:post_block(B) || B <- Chain2],
    wait_for_top_block_hash(Hash2),

    %% The mining should now have been preempted
    %% and started over with the new top block hash
    wait_for_start_mining(Hash2),

    %% TODO: check the transaction pool
    ok.

-define(error_atom, {error, A} when is_atom(A)).

test_chain_api() ->
    %% Stop the miner to be in a controlled environment
    aec_conductor:stop_mining(),
    wait_for_stopped(),

    %% Test that we have a genesis block to start out from.
    {ok, GenesisHeader} = ?TEST_MODULE:genesis_header(),
    GenesisHash = header_hash(GenesisHeader),
    ?assertMatch({ok, #block{}}, ?TEST_MODULE:genesis_block()),
    ?assertMatch({ok, #header{}}, ?TEST_MODULE:genesis_header()),
    ?assertEqual(GenesisHash, ?TEST_MODULE:genesis_hash()),

    %% Check the format of the top* functions
    ?assert(is_binary(?TEST_MODULE:top_block_hash())),
    ?assert(is_binary(?TEST_MODULE:top_header_hash())),
    ?assertMatch(#block{}, ?TEST_MODULE:top()),
    ?assertMatch(#header{}, ?TEST_MODULE:top_header()),

    %% Seed the server with a chain
    [_, B1, B2] = aec_test_utils:gen_block_chain(3),
    TopBlock = B2,
    TopHeader = aec_blocks:to_header(TopBlock),
    TopHash = block_hash(TopBlock),
    TopHeight = aec_blocks:height(TopBlock),
    ?assertEqual(ok, ?TEST_MODULE:post_block(B1)),
    ?assertEqual(ok, ?TEST_MODULE:add_synced_block(B2)),
    wait_for_top_block_hash(TopHash),

    FakeHash = <<"I am a fake hash">>,

    %% Check the chain access functions
    ?assertEqual({ok, TopBlock}, ?TEST_MODULE:get_block_by_hash(TopHash)),
    ?assertMatch(?error_atom, ?TEST_MODULE:get_block_by_hash(FakeHash)),
    ?assertEqual({ok, TopBlock}, ?TEST_MODULE:get_block_by_height(TopHeight)),
    ?assertMatch(?error_atom, ?TEST_MODULE:get_block_by_height(TopHeight + 1)),

    ?assertEqual({ok, TopHeader}, ?TEST_MODULE:get_header_by_hash(TopHash)),
    ?assertMatch(?error_atom, ?TEST_MODULE:get_header_by_hash(FakeHash)),
    ?assertEqual({ok, TopHeader}, ?TEST_MODULE:get_header_by_height(TopHeight)),
    ?assertMatch(?error_atom, ?TEST_MODULE:get_header_by_height(TopHeight + 1)),

    ?assertEqual(true, ?TEST_MODULE:hash_is_connected_to_genesis(TopHash)),
    ?assertEqual(false, ?TEST_MODULE:hash_is_connected_to_genesis(FakeHash)),

    ?assertEqual(true, ?TEST_MODULE:has_block(TopHash)),
    ?assertEqual(false, ?TEST_MODULE:has_block(FakeHash)),

    ?assertMatch({ok, F} when is_float(F), ?TEST_MODULE:get_total_difficulty()),
    ok.

test_block_publishing() ->
    %% Stop the miner to be in a controlled environment
    aec_conductor:stop_mining(),
    wait_for_stopped(),

    %% Generate a chain
    [_B0, B1, B2, B3, B4, B5] = Chain = aec_test_utils:gen_block_chain(6),
    [_H0, H1, H2, H3, H4, H5] = [block_hash(B) || B <- Chain],

    aec_events:subscribe(top_changed),
    aec_events:subscribe(block_created),

    %% Seed the server with the first part of the chain
    ok = ?TEST_MODULE:post_block(B1),
    wait_for_top_block_hash(H1),
    expect_top_event_hashes([H1]),
    ok = ?TEST_MODULE:post_block(B2),
    wait_for_top_block_hash(H2),
    expect_top_event_hashes([H2]),

    %% Make sure there are no other messages waiting for us
    ?assertEqual([], flush_gproc()),

    %% Start mining and wait for two blocks.
    aec_conductor:start_mining(),
    wait_for_block_created(),
    wait_for_block_created(),
    aec_conductor:stop_mining(),

    %% We should not have a new top event since we got the block_created events
    ?assertEqual([], flush_gproc()),

    %% Post the rest of the chain, which will take over eventually
    [?TEST_MODULE:post_block(B) || B <- [B2, B3, B4, B5]],
    wait_for_top_block_hash(H5),

    %% The first block cannot have taken over, so it should have no event
    %% We should have top_changed events for at least the last block.
    %% No top events should have been given for anything else than the headers
    TopHashes = expect_top_event_hashes([H3, H4, H5], [H3, H4]),

    %% And no other events should have been emitted.
    ?assertEqual([], flush_gproc()),
    ok.

%%%===================================================================
%%% Helpers
%%%===================================================================

block_hash(Block) ->
    {ok, Hash} = aec_blocks:hash_internal_representation(Block),
    Hash.

header_hash(Header) ->
    {ok, Hash} = aec_headers:hash_header(Header),
    Hash.

get_top_height() ->
    TopBlock = aec_conductor:top(),
    aec_blocks:height(TopBlock).

wait_for_stopped() ->
    aec_test_utils:wait_for_it(fun ?TEST_MODULE:get_mining_state/0, stopped).

wait_for_running() ->
    aec_test_utils:wait_for_it(fun ?TEST_MODULE:get_mining_state/0, running).

expect_top_event_hashes(Expected) ->
    expect_top_event_hashes(Expected, []).

expect_top_event_hashes([],_AllowMissing) ->
    ok;
expect_top_event_hashes(Expected, AllowMissing) ->
    receive
        {gproc_ps_event, top_changed, #{info := Block}} ->
            Hash = block_hash(Block),
            NewExpected = Expected -- [Hash],
            case lists:member(Hash, Expected) of
                true  -> expect_top_event_hashes(NewExpected, AllowMissing);
                false -> error({unexpected, Hash})
            end
    after 1000 ->
            case Expected -- AllowMissing of
                [] -> ok;
                Other -> error({missing, Other})
            end
    end.

wait_for_top_block_hash(Hash) ->
    aec_test_utils:wait_for_it(
      fun () -> aec_conductor:top_block_hash() end,
      Hash).

wait_for_block_created() ->
    _ = wait_for_gproc(block_created, 30000),
    ok.

wait_for_start_mining(Hash) ->
    Info = wait_for_gproc(start_mining, 1000),
    case proplists:get_value(top_block_hash, Info) of
        Hash -> ok;
        _Other -> wait_for_start_mining(Hash)
    end.

wait_for_gproc(Event, Timeout) ->
    receive
        {gproc_ps_event, Event, #{info := Info}} -> Info
    after Timeout -> error({timeout, block_created})
    end.

flush_gproc() ->
    flush_gproc([]).

flush_gproc(Acc) ->
    receive
        {gproc_ps_event, _, _} = E -> flush_gproc([E|Acc])
    after 0 -> Acc
    end.

-endif.