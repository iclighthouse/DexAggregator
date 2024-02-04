/**
 * Actor     : DexAggregator
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/DexAggregator
 */
import Array "mo:base/Array";
import Binary "mo:icl/Binary";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import DIP20 "mo:icl/DIP20";
import DRC20 "mo:icl/DRC20";
import DRC207 "mo:icl/DRC207";
import Float "mo:base/Float";
import Hash "mo:base/Hash";
import Hex "mo:icl/Hex";
import IC "mo:icl/IC";
import CF "mo:icl/CF";
import ICDex "mo:icl/ICDexTypes";
import Int "mo:base/Int";
import Int64 "mo:base/Int64";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import T "lib/Types";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Tools "mo:icl/Tools";
import List "mo:base/List";
import Trie "mo:base/Trie"; // fix a bug
import SHA224 "mo:sha224/SHA224";
import CRC32 "mo:icl/CRC32";
import ICRC1 "mo:icl/ICRC1";
import DRC205T "mo:icl/DRC205Types";
import ICTokens "mo:icl/ICTokens";
import Ledger "mo:icl/Ledger";
import ERC721 "mo:icl/ERC721";
import Timer "mo:base/Timer";
import Order "mo:base/Order";
import ICOracle "mo:icl/ICOracle";
import Error "mo:base/Error";

/*
Pair Score: 
score1 (max 70)
- (Not verified) ListingReferrer Propose: +10 / Sponsor
- Verified ListingReferrer Propose: +15 / Sponsor
- Sponsored (Sponsors >= 5): +10
score2 (max 20)
- SNS proposal sets Score +0 ~ 20
score3
- (pair_vol_token1_usd / 10000 / max(years, 1)) ^ 0.5 / 2
- (pair_liquidity_token1_usd / 10000) ^ 0.5 * 2
STAGE2: upgrade score >= 60, 1 month; degrade score < 50, 3 months
STAGE1: upgrade score >= 30; degrade score < 20, 3 months
STAGE0: default
*/
shared(installMsg) actor class DexAggregator() = this {
    type Txid = T.Txid;  //Blob
    type AccountId = T.AccountId;
    type Address = T.Address;
    type Nonce = T.Nonce;
    type DexName = T.DexName;
    type TokenStd = T.TokenStd;
    type TokenSymbol = T.TokenSymbol;
    type TokenInfo = T.TokenInfo;
    type ListingReferrer = T.ListingReferrer;
    type TxnStatus = T.TxnStatus;
    type TxnResult = T.TxnResult;
    type PairCanisterId = T.PairCanister;
    type PairRequest = T.PairRequest;
    type PairInfo = T.PairInfo;
    type PairResponse = T.PairResponse;
    type TrieList<K, V> = T.TrieList<K, V>;
    type DexCompetition = T.DexCompetition;
    type DexCompetitionResponse = T.DexCompetitionResponse;
    type TraderStats = T.TraderStats;
    type TraderData = T.TraderData;
    type TraderDataResponse = T.TraderDataResponse;
    type FilledTrade = T.FilledTrade;
    type MarketBoard = T.MarketBoard;
    type TradingPair = T.TradingPair;
    type Timestamp = Nat; // seconds

    private stable var setting = {
        SYS_TOKEN: Principal = Principal.fromText("5573k-xaaaa-aaaak-aacnq-cai");
        BLACKHOLE: Principal = Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai");
        ORACLE: Principal = Principal.fromText("pncff-zqaaa-aaaai-qnp3a-cai");
        SCORE_G1: Nat = 60; // 60
        SCORE_G2: Nat = 50; // 50
        SCORE_G3: Nat = 25; // 25
        SCORE_G4: Nat = 20; // 20
    };
    private let version_: Text = "0.8.7";
    private let ic: IC.Self = actor("aaaaa-aa");
    private let usd_decimals: Nat = 18;
    private let icp_: Principal = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
    private stable var oracleData: ([ICOracle.DataResponse], Timestamp) = ([], 0); // ICP/USD sid=2
    // private stable var pause: Bool = false; 
    // private stable var owner: Principal = installMsg.caller;
    private stable var sysToken: ICRC1.Self = actor(Principal.toText(setting.SYS_TOKEN));
    private stable var lastMonitorTime: Time.Time = 0;
    private stable var dexList =  List.nil<(DexName, Principal)>(); 
    private stable var pairs: Trie.Trie<PairCanisterId, (pair: PairInfo, score: Nat)> = Trie.empty(); // deprecated
    private stable var tradingPairs: Trie.Trie<PairCanisterId, TradingPair> = Trie.empty(); 
    private stable var markets: Trie.Trie<Text, [PairCanisterId]> = Trie.empty(); // ICP USDT....
    private stable var pairSponsors: Trie.Trie<PairCanisterId, (sponsored: Bool, listingReferrers: [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)])> = Trie.empty();
    private stable var pairLiquidity: Trie.Trie<PairCanisterId, (liquidity: ICDex.Liquidity, time: Time.Time)> = Trie.empty();
    private stable var pairLiquidity2: Trie.Trie<PairCanisterId, (liquidity: ICDex.Liquidity2, time: Time.Time)> = Trie.empty();
    private stable var listingReferrers: Trie.Trie<Principal, ListingReferrer> = Trie.empty();
    // private stable var competitions: Trie.Trie<PairCanisterId, (round: Nat, name: Text, start: Time.Time, end: Time.Time)> = Trie.empty();
    private stable var dexCompetitionIndex : Nat = 0;
    private stable var dexCompetitions: Trie.Trie<Nat, DexCompetition> = Trie.empty();
    private stable var dexCompetitionClosedPrice: Trie.Trie<Nat, [(Principal, Float, Time.Time)]> = Trie.empty();
    private stable var dexCompetitionTraders: Trie.Trie2D<Nat, AccountId, [TraderData]> = Trie.empty();
    private stable var wasm: [Nat8] = [];
    private stable var wasmVersion: Text = "";
    
    //private stable var tokens: Trie.Trie<Principal, [PairInfo]> = Trie.empty(); // **
    private stable var currencies =  List.nil<TokenInfo>(); 
    private stable var index: Nat = 0;

    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };
    private func trieItems<K, V>(_trie: Trie.Trie<K,V>, _page: Nat, _size: Nat) : TrieList<K, V> {
        let length = Trie.size(_trie);
        if (_page < 1 or _size < 1){
            return {data = []; totalPage = 0; total = length; };
        };
        let offset = Nat.sub(_page, 1) * _size;
        var totalPage: Nat = length / _size;
        if (totalPage * _size < length) { totalPage += 1; };
        if (offset >= length){
            return {data = []; totalPage = totalPage; total = length; };
        };
        let end: Nat = offset + Nat.sub(_size, 1);
        var i: Nat = 0;
        var res: [(K, V)] = [];
        for ((k,v) in Trie.iter<K, V>(_trie)){
            if (i >= offset and i <= end){
                res := Tools.arrayAppend(res, [(k,v)]);
            };
            i += 1;
        };
        return {data = res; totalPage = totalPage; total = length; };
    };

    /* 
    * Local Functions
    */
    private func _onlyOwner(_caller: Principal) : Bool { 
        return Principal.isController(_caller);
    };  // assert(_onlyOwner(msg.caller));
    // private func _notPaused() : Bool { 
    //     return not(pause);
    // };
    private func _onlyDexList(_caller: Principal) : Bool { 
        return Option.isSome(List.find(dexList, func (item:(DexName, Principal)):Bool{ item.1 == _caller }));
    };
    private func _onlyPair(_caller: Principal) : Bool { 
        return Option.isSome(Trie.find(tradingPairs, keyp(_caller), Principal.equal));
    };
    private func _inDexList(_name: DexName) : Bool { 
        return Option.isSome(List.find(dexList, func (item:(DexName, Principal)):Bool{ item.0 == _name }));
    };
    private func _now() : Timestamp{
        return Int.abs(Time.now() / 1_000_000_000);
    };
    private func _natToFloat(_n: Nat) : Float{
        let n: Int = _n;
        return Float.fromInt(n);
    };
    private func _floatToNat(_f: Float) : Nat{
        let i = Float.toInt(_f);
        assert(i >= 0);
        return Int.abs(i);
    };
    private func _accountIdToHex(_a: AccountId) : Text{
        return Hex.encode(Blob.toArray(_a));
    };
    private func _getAccountId(_address: Address): AccountId{
        switch (Tools.accountHexToAccountBlob(_address)){
            case(?(a)){
                return a;
            };
            case(_){
                var p = Principal.fromText(_address);
                var a = Tools.principalToAccountBlob(p, null);
                return a;
            };
        };
    }; 
    private func _getDexName(_dex: Principal) : DexName { 
        switch(List.find(dexList, func (item:(DexName, Principal)):Bool{ item.1 == _dex })){
            case(?(name, principal)){ return name; };
            case(_){ return ""; };
        };
    };
    // private func _drc20TransferFrom(_token: Principal, _from: AccountId, _to: AccountId, _value: Nat) : async Bool{
    //     let token0: DRC20.Self = actor(Principal.toText(_token));
    //     let res = await token0.drc20_transferFrom(_accountIdToHex(_from), _accountIdToHex(_to), _value, null,null,null);
    //     switch(res){
    //         case(#ok(txid)){ return true; };
    //         case(#err(e)){ return false; };
    //     };
    // };
    // private func _drc20Transfer(_token: Principal, _to: AccountId, _value: Nat) : async Bool{
    //     let token: DRC20.Self = actor(Principal.toText(_token));
    //     let res = await token.drc20_transfer(_accountIdToHex(_to), _value, null,null,null);
    //     switch(res){
    //         case(#ok(txid)){ return true; };
    //         case(#err(e)){ return false; };
    //     };
    // };
    // private func _icrc1Transfer(_token: Principal, _to: {owner: Principal; subaccount: ?Blob}, _value: Nat) : async Bool{
    //     let token: ICRC1.Self = actor(Principal.toText(_token));
    //     let args : ICRC1.TransferArgs = {
    //         memo = null;
    //         amount = _value;
    //         fee = null;
    //         from_subaccount = null;
    //         to = _to;
    //         created_at_time = null;
    //     };
    //     let res = await token.icrc1_transfer(args);
    //     switch(res){
    //         case(#ok(txid)){ return true; };
    //         case(#err(e)){ return false; };
    //     };
    // };
    private func _updatePair(_pair: PairInfo) : async (){
        var feeRate: Float = 0;
        if (_pair.dexName == "icdex"){
            let pair: ICDex.Self = actor(Principal.toText(_pair.canisterId));
            feeRate := (await pair.fee()).taker.buy;
        }else if (_pair.dexName == "icswap"){
            let pair: ICDex.Self = actor(Principal.toText(_pair.canisterId));
            feeRate := (await pair.feeStatus()).feeRate;
        }else if (_pair.dexName == "cyclesfinance"){
            let pair: CF.Self = actor(Principal.toText(_pair.canisterId));
            feeRate := (await pair.feeStatus()).fee;
        }else{
            // ELSE DEX
        };
        switch(Trie.get(tradingPairs, keyp(_pair.canisterId), Principal.equal)){
            case(?tradingPair){
                tradingPairs := Trie.put(tradingPairs, keyp(_pair.canisterId), Principal.equal, {
                    pair = {
                        token0 = _pair.token0; 
                        token1 = _pair.token1; 
                        dexName = _pair.dexName; 
                        canisterId = _pair.canisterId; 
                        feeRate = feeRate; 
                    };
                    marketBoard = tradingPair.marketBoard;
                    score1 = tradingPair.score1;
                    score2 = tradingPair.score2;
                    score3 = tradingPair.score3;
                    startingOverG1 = tradingPair.startingOverG1;
                    startingBelowG2 = tradingPair.startingBelowG2;
                    startingBelowG4 = tradingPair.startingBelowG4;
                    createdTime = tradingPair.createdTime;
                    updatedTime = tradingPair.updatedTime;
                }).0;
            };
            case(_){};
        };
    };

    private func _updateMarketBoard(_pair: TradingPair) : TradingPair{
        let score = _pair.score1 + _pair.score2 + _pair.score3;
        let t3months = 90 * 24 * 3600;
        let t1months = 30 * 24 * 3600;
        var startingOverG1 = _pair.startingOverG1;
        var startingBelowG2 = _pair.startingBelowG2;
        var startingBelowG4 = _pair.startingBelowG4;
        var marketBoard = _pair.marketBoard;
        if (marketBoard == #STAGE0 and score >= setting.SCORE_G3){
            marketBoard := #STAGE1;
        }else if (marketBoard == #STAGE1 and score < setting.SCORE_G4){
            if (Option.isNull(startingBelowG4)){
                startingBelowG4 := ?_now();
            }else if (_now() > Option.get(startingBelowG4, 0) + t3months){
                marketBoard := #STAGE0;
                startingBelowG4 := null;
            };
        }else if (marketBoard == #STAGE1 and score >= setting.SCORE_G1){
            if (Option.isNull(startingOverG1)){
                startingOverG1 := ?_now();
            }else if (_now() > Option.get(startingOverG1, 0) + t1months){
                marketBoard := #STAGE2;
                startingOverG1 := null;
            };
        }else if (marketBoard == #STAGE1){
            startingOverG1 := null;
            startingBelowG4 := null;
        }else if (marketBoard == #STAGE2 and score < setting.SCORE_G2){
            if (Option.isNull(startingBelowG2)){
                startingBelowG2 := ?_now();
            }else if (_now() > Option.get(startingBelowG2, 0) + t3months){
                marketBoard := #STAGE1;
                startingBelowG2 := null;
            };
        }else if (marketBoard == #STAGE2){
            startingBelowG2 := null;
        };
        return {
            pair = _pair.pair;
            marketBoard = marketBoard;
            score1 = _pair.score1;
            score2 = _pair.score2;
            score3 = _pair.score3;
            startingOverG1 = startingOverG1;
            startingBelowG2 = startingBelowG2;
            startingBelowG4 = startingBelowG4;
            createdTime = _pair.createdTime;
            updatedTime = _now();
        };
    };
    private func _addScore1(_pair: PairCanisterId, _add: Nat) : (){
        switch(Trie.get(tradingPairs, keyp(_pair), Principal.equal)){
            case(?(pair)){
                tradingPairs := Trie.put(tradingPairs, keyp(_pair), Principal.equal, _updateMarketBoard({
                    pair = pair.pair;
                    marketBoard = pair.marketBoard;
                    score1 = Nat.min(pair.score1 + _add, 70);
                    score2 = pair.score2;
                    score3 = pair.score3;
                    startingOverG1 = pair.startingOverG1;
                    startingBelowG2 = pair.startingBelowG2;
                    startingBelowG4 = pair.startingBelowG4;
                    createdTime = pair.createdTime;
                    updatedTime = pair.updatedTime;
                })).0;
            };
            case(_){};
        };
    };
    private func _setScore2(_pair: PairCanisterId, _set: Nat) : (){
        switch(Trie.get(tradingPairs, keyp(_pair), Principal.equal)){
            case(?(pair)){
                tradingPairs := Trie.put(tradingPairs, keyp(_pair), Principal.equal, _updateMarketBoard({
                    pair = pair.pair;
                    marketBoard = pair.marketBoard;
                    score1 = pair.score1;
                    score2 = Nat.min(_set, 20);
                    score3 = pair.score3;
                    startingOverG1 = pair.startingOverG1;
                    startingBelowG2 = pair.startingBelowG2;
                    startingBelowG4 = pair.startingBelowG4;
                    createdTime = pair.createdTime;
                    updatedTime = pair.updatedTime;
                })).0;
            };
            case(_){};
        };
    };
    private func _calcuScore3(createTs: Timestamp, volUsd: Nat, liquidityUsd: Nat): Nat{
        let durationYears = Nat.sub(_now(), createTs) / 365 / 24 / 3600;
        // (vol_usd / 10000 / max(years, 1)) ^ 0.5 / 2    +   (liquidity_usd / 10000) ^ 0.5 * 2
        return _floatToNat(_natToFloat(volUsd / 10_000 / Nat.max(durationYears, 1)) ** 0.5) / 2 +
        _floatToNat(_natToFloat(liquidityUsd / 10_000) ** 0.5) * 2;
    };
    private func _setScore3(_pair: PairCanisterId, _volUsd: Nat, _liquidityUsd: Nat) : (){
        switch(Trie.get(tradingPairs, keyp(_pair), Principal.equal)){
            case(?(pair)){
                tradingPairs := Trie.put(tradingPairs, keyp(_pair), Principal.equal, _updateMarketBoard({
                    pair = pair.pair;
                    marketBoard = pair.marketBoard;
                    score1 = pair.score1;
                    score2 = pair.score2;
                    score3 = _calcuScore3(pair.createdTime, _volUsd, _liquidityUsd);
                    startingOverG1 = pair.startingOverG1;
                    startingBelowG2 = pair.startingBelowG2;
                    startingBelowG4 = pair.startingBelowG4;
                    createdTime = pair.createdTime;
                    updatedTime = pair.updatedTime;
                })).0;
            };
            case(_){};
        };
    };
    private func _adjustPair(_pair: PairRequest) : (pair: PairRequest){
        var value0: Nat64 = 0;
        var value1: Nat64 = 1;
        if (_pair.dexName == "icswap"){
            value0 := Binary.BigEndian.toNat64(Tools.slice(Blob.toArray(Principal.toBlob(_pair.token0.0)), 0, ?8));
            value1 := Binary.BigEndian.toNat64(Tools.slice(Blob.toArray(Principal.toBlob(_pair.token1.0)), 0, ?8));
        };
        assert(value0 != value1);
        if (value0 < value1){
            return _pair;
        }else{
            return {token0 = _pair.token1; token1 = _pair.token0; dexName = _pair.dexName; };
        };
    };
    private func _adjustPair2(_pair: PairInfo) : (pair: PairInfo){
        var value0: Nat64 = 0;
        var value1: Nat64 = 1;
        if (_pair.dexName == "icswap"){
            value0 := Binary.BigEndian.toNat64(Tools.slice(Blob.toArray(Principal.toBlob(_pair.token0.0)), 0, ?8));
            value1 := Binary.BigEndian.toNat64(Tools.slice(Blob.toArray(Principal.toBlob(_pair.token1.0)), 0, ?8));
        };
        assert(value0 != value1);
        if (value0 < value1){
            return _pair;
        }else{
            return {token0 = _pair.token1; token1 = _pair.token0; dexName = _pair.dexName; canisterId = _pair.canisterId; feeRate = _pair.feeRate; };
        };
    };
    private func _inCurrencies(_token: Principal) : Bool{
        return Option.isSome(List.find(currencies, func (t: TokenInfo): Bool{ t.0 == _token }));
    };
    private func _getPairsByToken(_mainToken: Principal, _dexName: ?DexName) : [(PairCanisterId, TradingPair)]{
        var trie = tradingPairs;
        if (Option.isSome(_dexName)){
            trie := Trie.filter(trie, func (k:PairCanisterId, v:TradingPair):Bool{ v.pair.dexName == Option.get(_dexName, ""); });
        };
        trie := Trie.filter(trie, func (k:PairCanisterId, v:TradingPair):Bool{ v.pair.token0.0 == _mainToken or v.pair.token1.0 == _mainToken; });
        return Iter.toArray(Trie.iter(trie));
    };
    private func _route(_token0: Principal, _token1: Principal, _dexName: ?DexName) : [(PairCanisterId, TradingPair)]{
        var trie = tradingPairs;
        if (Option.isSome(_dexName)){
            trie := Trie.filter(trie, func (k:PairCanisterId, v:TradingPair):Bool{ v.pair.dexName == Option.get(_dexName, ""); });
        };
        trie := Trie.filter(trie, func (k: PairCanisterId, v: TradingPair): Bool{ 
            (v.pair.token0.0 == _token0 and v.pair.token1.0 == _token1) or (v.pair.token1.0 == _token0 and v.pair.token0.0 == _token1)
        });
        return Iter.toArray(Trie.iter(trie));
    };
    private func _putPair(caller: ?Principal, pair: PairInfo): (){
        switch(Trie.get(tradingPairs, keyp(pair.canisterId), Principal.equal)){
            case(?(tradingPair)){
                if (Option.isNull(caller) or tradingPair.pair.dexName == _getDexName(Option.get(caller, Principal.fromActor(this)))){
                    tradingPairs := Trie.put(tradingPairs, keyp(pair.canisterId), Principal.equal, {
                        pair = pair;
                        marketBoard = tradingPair.marketBoard;
                        score1 = tradingPair.score1;
                        score2 = tradingPair.score2;
                        score3 = tradingPair.score3;
                        startingOverG1 = tradingPair.startingOverG1;
                        startingBelowG2 = tradingPair.startingBelowG2;
                        startingBelowG4 = tradingPair.startingBelowG4;
                        createdTime = tradingPair.createdTime;
                        updatedTime = _now();
                    }).0;
                    _autoPutMarket(pair);
                };
            };
            case(_){
                tradingPairs := Trie.put(tradingPairs, keyp(pair.canisterId), Principal.equal, {
                    pair = pair;
                    marketBoard = #STAGE0;
                    score1 = 0;
                    score2 = 0;
                    score3 = 0;
                    startingOverG1 = null;
                    startingBelowG2 = null;
                    startingBelowG4 = null;
                    createdTime = _now();
                    updatedTime = _now();
                }).0;
                _autoPutMarket(pair);
            };
        };
    };
    private func _putMarket(_name: Text, _canisterId: PairCanisterId): (){
        switch(Trie.get(markets, keyt(_name), Text.equal)){
            case(?(items)){
                let canisterIds = Array.filter(items, func (t: PairCanisterId): Bool{ t != _canisterId });
                markets := Trie.put(markets, keyt(_name), Text.equal, Tools.arrayAppend(canisterIds, [_canisterId])).0;
            };
            case(_){
                markets := Trie.put(markets, keyt(_name), Text.equal, [_canisterId]).0;
            };
        };
    };
    private func _autoPutMarket(_pair: PairInfo): (){
        _putMarket(_pair.token1.1, _pair.canisterId);
    };
    private func _removePairFromMarket(_name: Text, _canisterId: PairCanisterId): (){
        switch(Trie.get(markets, keyt(_name), Text.equal)){
            case(?(items)){
                let canisterIds = Array.filter(items, func (t: PairCanisterId): Bool{ t != _canisterId });
                markets := Trie.put(markets, keyt(_name), Text.equal, canisterIds).0;
            };
            case(_){};
        };
    };
    private func _removePairFromAllMarkets(_canisterId: PairCanisterId): (){
        for ((market, items) in Trie.iter(markets)){
            let canisterIds = Array.filter(items, func (t: PairCanisterId): Bool{ t != _canisterId });
            markets := Trie.put(markets, keyt(market), Text.equal, canisterIds).0;
        };
    };
    private func _getMarket(_name: Text): [TradingPair]{
        switch(Trie.get(markets, keyt(_name), Text.equal)){
            case(?(items)){
                return Array.mapFilter(items, func (t: PairCanisterId): ?TradingPair{
                    Trie.get(tradingPairs, keyp(t), Principal.equal);
                });
            };
            case(_){
                return [];
            };
        };
    };
    private func _fetchOracleFeed(): async* (){
        let oralce: ICOracle.Self = actor(Principal.toText(setting.ORACLE));
        let res = await oralce.latest(#Crypto);
        oracleData := (res, _now());
    };
    private func _getPrice(_token: Principal): Nat{ // 1 smallest _token = ? smallest USDT
        var sid: Nat = 0;
        var unit: Nat = 1;
        if (_token == icp_){
            sid := 2;
            unit := 10_000_000_000; // USDT_Decimals 18 - ICP_Decimals 8
        }else/* if (_token == usdt_)*/{
            return 1; // USDT
        };
        for(item in oracleData.0.vals()){
            if (item.sid == sid){
                return  unit * item.data.1 / (10 ** item.decimals);
            };
        };
        return 0;
    };

    /* =====================
      Pair List and Router
    ====================== */
    public query func getTokens(_dexName: ?DexName) : async [TokenInfo]{
        var trie = tradingPairs;
        if (Option.isSome(_dexName)){
            trie := Trie.filter(trie, func (k:PairCanisterId, v:TradingPair):Bool{ v.pair.dexName == Option.get(_dexName, ""); });
        };
        var res: [TokenInfo] = [];
        for ((canister, pair) in Trie.iter(trie)){
            if (Option.isNull(Array.find(res, func (t:TokenInfo):Bool{ t.0 == pair.pair.token0.0 }))){
                res := Tools.arrayAppend(res, [pair.pair.token0]);
            };
            if (Option.isNull(Array.find(res, func (t:TokenInfo):Bool{ t.0 == pair.pair.token1.0 }))){
                res := Tools.arrayAppend(res, [pair.pair.token1]);
            };
        };
        return res;
    };
    public query func getPairs(_dexName: ?DexName, _page: ?Nat, _size: ?Nat) : async TrieList<PairCanisterId, TradingPair>{
        var trie = tradingPairs;
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        if (Option.isSome(_dexName)){
            trie := Trie.filter(trie, func (k:PairCanisterId, v:TradingPair):Bool{ v.pair.dexName == Option.get(_dexName, ""); });
        };
        return trieItems(trie, page, size);
    };
    public query func getPairsByToken(_token: Principal, _dexName: ?DexName) : async [(PairCanisterId, TradingPair)]{
        return _getPairsByToken(_token, _dexName);
    };
    public query func route(_token0: Principal, _token1: Principal, _dexName: ?DexName) : async [(PairCanisterId, TradingPair)]{
        return _route(_token0, _token1, _dexName);
    };
    public shared(msg) func putByDex(_token0: TokenInfo, _token1: TokenInfo, _canisterId: Principal) : async (){
        assert(_onlyDexList(msg.caller));
        let pair = _adjustPair2({
            token0 = _token0; 
            token1 = _token1; 
            dexName = _getDexName(msg.caller); 
            canisterId = _canisterId;
            feeRate = 0.0; 
        });
        _putPair(?msg.caller, pair);
        await _updatePair(pair);
    };
    public shared(msg) func removeByDex(_pairCanister: Principal) : async (){
        assert(_onlyDexList(msg.caller));
        switch(Trie.get(tradingPairs, keyp(_pairCanister), Principal.equal)){
            case(?(pair)){
                if (pair.pair.dexName == _getDexName(msg.caller)){
                    tradingPairs := Trie.filter(tradingPairs, func (k: PairCanisterId, v: TradingPair): Bool{ 
                        _pairCanister != k;
                    });
                    _removePairFromAllMarkets(_pairCanister);
                };
            };
            case(_){};
        };
    };
    // public shared(msg) func pushCompetitionByPair(_round: Nat, _name: Text, _start: Time.Time, _end: Time.Time) : async (){
    //     assert(_onlyPair(msg.caller));
    //     competitions := Trie.put(competitions, keyp(msg.caller), Principal.equal, (_round, _name, _start, _end)).0;
    //     // competitions := Trie.filter(competitions, func (k: Principal, v:(Nat,Text,Int,Int)): Bool{ Time.now() < v.3 + 365*24*3600*1000000000 });
    // };
    public query func getDexList() : async [(DexName, Principal)]{
        return List.toArray(dexList);
    };
    public query func getCurrencies() : async [TokenInfo]{
        return List.toArray(currencies);
    };
    public query func getPairsByMarket(_market: Text, _dexName: ?DexName, _page: ?Nat, _size: ?Nat): async TrieList<PairCanisterId, TradingPair>{
        var marketPairs = _getMarket(_market);
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        assert(page >= 1 and size >= 1);
        if (Option.isSome(_dexName)){
            marketPairs := Array.filter(marketPairs, func (t: TradingPair): Bool{ t.pair.dexName == Option.get(_dexName, ""); });
        };
        let data = Array.map<TradingPair, (PairCanisterId, TradingPair)>(marketPairs, func (t: TradingPair): (PairCanisterId, TradingPair){
            (t.pair.canisterId, t)
        });
        let length = Array.size(data);
        let offset = Nat.sub(page, 1) * size;
        var totalPage: Nat = length / size;
        if (totalPage * size < length) { totalPage += 1; };
        if (offset >= length){
            return {data = []; totalPage = totalPage; total = length; };
        };
        let end: Nat = offset + Nat.sub(size, 1);
        return {data = Tools.slice(data, offset, ?end); total = length; totalPage = totalPage; };
    };


    
    /* =====================
      Admin
    ====================== */
    public shared(msg) func sync() : async (){ // sync fee
        assert(_onlyOwner(msg.caller));
        for ((canister, pair) in Trie.iter(tradingPairs)){
            let r = await _updatePair(pair.pair);
        };
    };
    //'(record{token0=record{principal "f2r76-wqaaa-aaaak-adpzq-cai"; "ITest"; variant{icrc1}}; token1=record{principal "f5qzk-3iaaa-aaaak-adpza-cai"; "DTest"; variant{drc20}}; dexName="icdex"; canisterId=principal "dklbo-qyaaa-aaaak-adqjq-cai"; feeRate=0.005}, 1)'
    public shared(msg) func put(_pair: PairInfo, _score: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        let pair = _adjustPair2(_pair);
        _putPair(?msg.caller, pair);
        await _updatePair(pair);
        _setScore2(_pair.canisterId, _score);
    };
    public shared(msg) func remove(_pairCanister: Principal) : async (){
        assert(_onlyOwner(msg.caller));
        tradingPairs := Trie.filter(tradingPairs, func (k: PairCanisterId, v: TradingPair): Bool{ 
            _pairCanister != k;
        });
        _removePairFromAllMarkets(_pairCanister);
    };
    public shared(msg) func setScore(_pairId: Principal, _score: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        _setScore2(_pairId, _score);
    };
    public shared(msg) func putCurrency(_cur: TokenInfo) : async (){
        assert(_onlyOwner(msg.caller));
        if (not(_inCurrencies(_cur.0))){
            currencies := List.push(_cur, currencies);
        };
    };
    public shared(msg) func removeCurrency(_curToken: Principal) : async (){
        assert(_onlyOwner(msg.caller));
        currencies := List.filter(currencies, func(t: TokenInfo):Bool{ t.0 != _curToken });
    };
    public shared(msg) func setDex(_name: DexName, _canisterId: Principal) : async (){
        assert(_onlyOwner(msg.caller));
        if (not(_onlyDexList(_canisterId))){
            dexList := List.push((_name, _canisterId), dexList);
        }
    };
    public shared(msg) func delDex(_canisterId: Principal) : async (){
        assert(_onlyOwner(msg.caller));
        dexList := List.filter(dexList, func(t: (DexName, Principal)):Bool{ t.1 != _canisterId });
    };

    public shared(msg) func autoPutPairToMarket(_pairCanisterId: PairCanisterId) : async (){
        switch(Trie.get(tradingPairs, keyp(_pairCanisterId), Principal.equal)){
            case(?(tradingPair)){
                _autoPutMarket(tradingPair.pair);
            };
            case(_){};
        };
    };
    public shared(msg) func putPairToMarket(_market: Text, _pairCanisterId: PairCanisterId) : async (){
        assert(_onlyOwner(msg.caller));
        _putMarket(_market, _pairCanisterId);
    };
    public shared(msg) func removePairFromMarket(_market: ?Text, _pairCanisterId: PairCanisterId) : async (){
        assert(_onlyOwner(msg.caller));
        switch(_market){
            case(?(market)){ _removePairFromMarket(market, _pairCanisterId) };
            case(_){ _removePairFromAllMarkets(_pairCanisterId) }
        };
    };

    public query func version() : async Text{
        return version_;
    };
    public query func getConfig() : async T.Config{
        return setting;
    };
    public shared(msg) func config(config: T.ConfigRequest) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        setting := {
            SYS_TOKEN: Principal = Option.get(config.SYS_TOKEN, setting.SYS_TOKEN);
            BLACKHOLE: Principal = Option.get(config.BLACKHOLE, setting.BLACKHOLE);
            ORACLE: Principal = Option.get(config.ORACLE, setting.ORACLE);
            SCORE_G1: Nat = Option.get(config.SCORE_G1, setting.SCORE_G1);
            SCORE_G2: Nat = Option.get(config.SCORE_G2, setting.SCORE_G2);
            SCORE_G3: Nat = Option.get(config.SCORE_G3, setting.SCORE_G3);
            SCORE_G4: Nat = Option.get(config.SCORE_G4, setting.SCORE_G4);
        };
        return true;
    };

    public shared(msg) func sys_withdraw(_token: Principal, _tokenStd: TokenStd, _to: Principal, _value: Nat) : async (){ 
        assert(_onlyOwner(msg.caller));
        let account = Tools.principalToAccountBlob(_to, null);
        let address = Tools.principalToAccountHex(_to, null);
        if (_tokenStd == #drc20){
            let token: DRC20.Self = actor(Principal.toText(_token));
            let res = await token.drc20_transfer(address, _value, null, null, null);
        }else if (_tokenStd == #dip20){
            let token: DIP20.Self = actor(Principal.toText(_token));
            let res = await token.transfer(_to, _value);
        }else if (_tokenStd == #icrc1){
            let token: ICRC1.Self = actor(Principal.toText(_token));
            let args : ICRC1.TransferArgs = {
                memo = null;
                amount = _value;
                fee = null;
                from_subaccount = null;
                to = {owner = _to; subaccount = null};
                created_at_time = null;
            };
            let res = await token.icrc1_transfer(args);
        }else if (_tokenStd == #icp){
            let token: Ledger.Self = actor(Principal.toText(_token));
            let args : Ledger.TransferArgs = {
                memo = 0;
                amount = { e8s = Nat64.fromNat(_value) };
                fee = { e8s = 10000 };
                from_subaccount = null;
                to = account;
                created_at_time = null;
            };
            let res = await token.transfer(args);
        }
    };
    public shared(msg) func sys_burn(_value: Nat) : async (){
        assert(_onlyOwner(msg.caller));
        let token: ICRC1.Self = actor(Principal.toText(setting.SYS_TOKEN));
        let args : ICRC1.TransferArgs = {
            memo = null;
            amount = _value;
            fee = null;
            from_subaccount = null;
            to = {owner = setting.BLACKHOLE; subaccount = null};
            created_at_time = null;
        };
        let res = await token.icrc1_transfer(args);
    };

    /* =====================
      Listing Referrer
    ====================== */
    private func _onlyReferrer(_caller: Principal) : Bool { 
        switch(Trie.get(listingReferrers, keyp(_caller), Principal.equal)){
            case(?(referrer)){
                return Option.isNull(referrer.end) or Time.now() < Option.get(referrer.end, 0);
            };
            case(_){};
        };
        return false;
    };
    private func _onlyVerifiedReferrer(_caller: Principal) : Bool { 
        switch(Trie.get(listingReferrers, keyp(_caller), Principal.equal)){
            case(?(referrer)){
                return referrer.verified and (Option.isNull(referrer.end) or Time.now() < Option.get(referrer.end, 0));
            };
            case(_){};
        };
        return false;
    };
    private func _checkAndSetSponsor(_pair: PairCanisterId, _sponsored: Bool, _referrers: [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)], _referrer: Principal, _nftId: ERC721.TokenIdentifier) : 
    (Bool, [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)]){
        var count = _referrers.size();
        var referrerCount : Nat = 0;
        var verifiedCount : Nat = 0;
        var inArray : Bool = false;
        var sponsored : Bool = _sponsored;
        var referrers : [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)] = [];
        for ((lr, time, nftId) in referrers.vals()){
            if (_onlyReferrer(lr.referrer)) { 
                referrerCount += 1;
                referrers := Tools.arrayAppend(referrers, [(lr, time, nftId)]);
            };
            if (_onlyVerifiedReferrer(lr.referrer)) { 
                verifiedCount += 1; 
            };
            if (nftId == _nftId) { inArray := true; };
        };
        if (not(inArray)){
            switch(Trie.get(listingReferrers, keyp(_referrer), Principal.equal)){
                case(?(referrer)){
                    if (_onlyReferrer(_referrer)) { 
                        referrers := Tools.arrayAppend(referrers, [(referrer, Time.now(), _nftId)]);
                        referrerCount += 1;
                        if (referrerCount > count) { _addScore1(_pair, 10);};
                    };
                    if (_onlyVerifiedReferrer(_referrer)) { 
                        verifiedCount += 1; 
                        if (referrerCount > count) { _addScore1(_pair, 5);}; // 10 + 5
                    };
                };
                case(_){ };
            };
        };
        if (not(sponsored) and referrerCount >= 5){
            sponsored := true;
            _addScore1(_pair, 10);
        };
        return (sponsored, referrers);
    };
    private func _propose(_pair: PairCanisterId, _referrer: Principal, _nftId: ERC721.TokenIdentifier) : (){
        switch(Trie.get(pairSponsors, keyp(_pair), Principal.equal)){
            case(?(sponsor)){
                pairSponsors := Trie.put(pairSponsors, keyp(_pair), Principal.equal, _checkAndSetSponsor(_pair, sponsor.0, sponsor.1, _referrer, _nftId)).0;
            };
            case(_){
                pairSponsors := Trie.put(pairSponsors, keyp(_pair), Principal.equal, _checkAndSetSponsor(_pair, false, [], _referrer, _nftId)).0;
            };
        };
    };
    private func _updateLiquidity() : async* (){
        var i : Nat = 0;
        for ((k,v) in Trie.iter(tradingPairs)){
            var enUpdate : Bool = false;
            switch(Trie.get(pairLiquidity2, keyp(k), Principal.equal)){
                case(?(liquidity)){
                    if (Time.now() > liquidity.1 + 4 * 3600 * 1000000000){ enUpdate := true; };
                };
                case(_){ enUpdate := true; };
            };
            if (enUpdate and i < 200){
                i += 1;
                if (v.pair.dexName == "cyclesfinance" or v.pair.dexName == "icswap" or v.pair.dexName == "icdex"){
                    let mkt: ICDex.Self = actor(Principal.toText(k));
                    try{
                        let liquidity2 = await mkt.liquidity2(null);
                        pairLiquidity2 := Trie.put(pairLiquidity2, keyp(k), Principal.equal, (liquidity2, Time.now())).0;
                        let vol = liquidity2.vol.value1 * _getPrice(v.pair.token1.0);
                        let liquidity = liquidity2.token1 * _getPrice(v.pair.token1.0);
                        let unit: Nat = 10 ** usd_decimals;
                        _setScore3(k, vol / unit, liquidity / unit);
                    }catch(e){};
                };
            };
        };
    };
    private func _getPairResponse(_dexName: ?DexName, _lr: ?Principal, _pair: PairCanisterId) : ?PairResponse{
        switch(Trie.get(tradingPairs, keyp(_pair), Principal.equal)){
            case(?(v)){
                if (Option.isNull(_dexName) or v.pair.dexName == Option.get(_dexName, "")){
                    var liquidity : ?ICDex.Liquidity2 = null;
                    var sponsored : Bool = false;
                    var lrs : [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)] = [];
                    switch(Trie.get(pairLiquidity2, keyp(_pair), Principal.equal)){
                        case(?(item)){ liquidity := ?item.0 };
                        case(_){};
                    };
                    switch(Trie.get(pairSponsors, keyp(_pair), Principal.equal)){
                        case(?(item)){ 
                            sponsored := item.0; 
                            lrs := item.1;
                            switch(_lr){
                                case(?(lr)){ 
                                    if (Option.isNull(Array.find(lrs, func (a:(ListingReferrer, Time.Time, ERC721.TokenIdentifier)): Bool{ a.0.referrer == lr }))){ 
                                        return null; 
                                    }
                                };
                                case(_){};
                            };
                        };
                        case(_){ };
                    };
                    return ?{
                        pair = v.pair; 
                        score = v.score1 + v.score2 + v.score3; 
                        createdTime = v.createdTime;
                        marketBoard = ?v.marketBoard;
                        liquidity = liquidity; 
                        sponsored = sponsored; 
                        listingReferrers = lrs;
                    }; 
                }else{
                    return null;
                };
            };
            case(_){ return null; };
        };
    };
    private func _setListingReferrer(_referrer: Principal, _item: ListingReferrer) : (){
        listingReferrers := Trie.put(listingReferrers, keyp(_referrer), Principal.equal, _item).0;
    };
    private func _dropListingReferrer(_referrer: Principal) : (){
        switch(Trie.get(listingReferrers, keyp(_referrer), Principal.equal)){
            case(?(referrer)){
                listingReferrers := Trie.put(listingReferrers, keyp(_referrer), Principal.equal, {
                    referrer = _referrer;
                    name = referrer.name;
                    verified = referrer.verified;
                    start = referrer.start;
                    end = ?Time.now();
                    nftId = "";
                }).0;
            };
            case(_){};
        };
    };
    public query func listingReferrer(_referrer: Principal): async (isListingReferrer: Bool, verified: Bool){
        return (_onlyReferrer(_referrer), _onlyVerifiedReferrer(_referrer));
    };
    public query func getPairListingReferrers(_pair: PairCanisterId) : async (sponsored: Bool, listingReferrers: [(ListingReferrer, Time.Time, ERC721.TokenIdentifier)]){
        switch(Trie.get(pairSponsors, keyp(_pair), Principal.equal)){
            case(?(item)){ return item };
            case(_){ return (false, []) };
        };
    };
    public shared(msg) func setListingReferrerByNft(_name: Text, _nftId: Text) : async (){
        let account = Tools.principalToAccountBlob(msg.caller, null);
        let _referrer = msg.caller;
        if (not(_onlyNFTHolder(account, ?_nftId, ?#URANUS))){
            throw Error.reject("You should stake URANUS NFT (ICLighthouse Planet Cards) to qualify as a Listing Referrer.");
        };
        listingReferrers := Trie.filter(listingReferrers, func (k:Principal, v:ListingReferrer): Bool{
            v.nftId == "" or v.nftId != _nftId
        });
        _setListingReferrer(_referrer: Principal, {
            referrer = _referrer;
            name = _name;
            verified = false;
            start = Time.now();
            end = null;
            nftId = _nftId;
        });
    };
    public shared(msg) func verifyListingReferrer(_referrer: Principal, _name: Text, _verified: Bool) : async (){
        assert(_onlyOwner(msg.caller));
        switch(Trie.get(listingReferrers, keyp(_referrer), Principal.equal)){
            case(?(item)){
                _setListingReferrer(_referrer: Principal, {
                    referrer = item.referrer;
                    name = _name;
                    verified = _verified;
                    start = item.start;
                    end = item.end;
                    nftId = item.nftId;
                });
            };
            case(_){
                throw Error.reject("Referrer does not exist!");
            };
        };
    };
    public shared(msg) func dropListingReferrer(_referrer: Principal) : async (){
        assert(_onlyOwner(msg.caller));
        _dropListingReferrer(_referrer);
    };
    /// For each pair proposed, NFT will add 30 days to the lock-up period. 
    /// After the lock-up period reaches 360 days it will not be possible to continue proposing.
    public shared(msg) func propose(_pair: PairCanisterId): async (){
        assert(_onlyReferrer(msg.caller));
        let account = Tools.principalToAccountBlob(msg.caller, null);
        switch(_findNFT(account, ?#URANUS, false)){
            case(?nft){
                _stake(account, "ListingReferrer", nft.1, 30 * 24 * 3600 * 1000000000); // 30 days
                _propose(_pair, msg.caller, nft.1);
            };
            case(_){
                throw Error.reject("#URANUS NFT does not exist!");
            };
        };
    };
    /// Get pair list with sponsors info
    public query func getPairs2(_dexName: ?DexName, _lr: ?Principal, _page: ?Nat, _size: ?Nat) : async TrieList<PairCanisterId, PairResponse>{
        var trie : Trie.Trie<PairCanisterId, PairResponse> = Trie.empty();
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        trie := Trie.mapFilter(tradingPairs, func (k:PairCanisterId, v:TradingPair): ?PairResponse { 
            return _getPairResponse(_dexName, _lr, k); 
        });
        return trieItems(trie, page, size);
    };

    /* =====================
      Dex Competitions
    ====================== */
    type TradeParse = {
        positionChange: Int;
        amountChange: Int;
        positionDirection: {#long; #short};
        tradeType: {#open; #close};
    };
    private var _fetchDexCompetitionDataTime: Time.Time = 0;
    private var _fetchClosedPriceTime: Time.Time = 0;
    private func _getCompetitionTrader(_round: Nat, _a: AccountId): ?[TraderData]{
        switch(Trie.get(dexCompetitionTraders, keyn(_round), Nat.equal)){
            case(?(traders)){
                switch(Trie.get(traders, keyb(_a), Blob.equal)){
                    case(?(data)){ ?data };
                    case(_){ null };
                };
            };
            case(_){ null };
        };
    };
    private func _updateCompetitionTrader(_round: Nat, _a: AccountId, _pair: Principal, _newStats: TraderStats): (){
        switch(_getCompetitionTrader(_round, _a)){
            case(?(items)){
                let newItems = Array.map(items, func (t: TraderData): TraderData{
                    if (t.pair == _pair and (t.data.size() == 0 or t.data[0].time < _newStats.time)){
                        return {
                            dexName = t.dexName;
                            pair = t.pair;
                            quoteToken =  t.quoteToken;
                            startTime = t.startTime;
                            data = Tools.arrayAppend([_newStats], t.data); // The latest data is placed at position [0].
                            endTime = t.endTime;
                            total = t.total;
                        };
                    }else{
                        return t;
                    };
                });
                dexCompetitionTraders := Trie.put2D(dexCompetitionTraders, keyn(_round), Nat.equal, keyb(_a), Blob.equal, newItems);
            };
            case(_){};
        };
    };
    private func _getCompetitionClosedPrice(_round: Nat, _pair: Principal): ?(Float, Time.Time){
        switch(Trie.get(dexCompetitionClosedPrice, keyn(_round), Nat.equal)){
            case(?(items)){
                switch(Array.find(items, func (t: (Principal, Float, Time.Time)): Bool{
                    t.0 == _pair
                })){
                    case(?(pair, price, time)){ ?(price, time) };
                    case(_){ null };
                };
            };
            case(_){ null };
        };
    };
    private func _setCompetitionClosedPrice(_round: Nat): async* (){
        type Pair = actor{ 
            stats : shared query() -> async {price:Float; change24h:Float; vol24h:{value0: Nat; value1: Nat}; totalVol:{value0: Nat; value1: Nat}}; 
        };
        switch(Trie.get(dexCompetitions, keyn(_round), Nat.equal)){
            case(?(competition)){
                var priceData: [(Principal, Float, Time.Time)] = [];
                for (pairInfo in competition.pairs.vals()){
                    let pair : Pair = actor(Principal.toText(pairInfo.1));
                    var lastPrice: Float = (await pair.stats()).price;
                    if (pairInfo.2 == #token0){
                        lastPrice := 1 / lastPrice;
                    };
                    priceData := Tools.arrayAppend(priceData, [(pairInfo.1, lastPrice, Time.now())]);
                };
                dexCompetitionClosedPrice := Trie.put(dexCompetitionClosedPrice, keyn(_round), Nat.equal, priceData).0;
            };
            case(_){};
        };
    };
    private func _aggregateCompetitionTrader(_round: Nat, _a: AccountId, _settle: Bool): async* (){
        if (Time.now() > _fetchClosedPriceTime + 15*60*1000000000){ // 15mins
            await* _setCompetitionClosedPrice(_round);
            _fetchClosedPriceTime := Time.now();
        };
        switch(_getCompetitionTrader(_round, _a)){
            case(?(items)){
                let newItems = Array.map(items, func (t: TraderData): TraderData{
                    if (Option.isNull(t.endTime)){
                        var closedPrice : Float = 0;
                        var time: Int = Time.now();
                        var quoteToken = t.quoteToken;
                        var position: Int = 0;
                        var avgPrice: Float = 0;
                        var capital: Float = 0;
                        var vol: Nat = 0;
                        var pnl : Float = 0;
                        var count : Nat = 0;
                        for (stats in Array.reverse(t.data).vals()){
                            //time := Int.max(time, stats.time);
                            capital := Float.max(capital, stats.capital);
                            vol += stats.vol;
                            pnl += stats.pnl;
                            count += stats.count;
                        };
                        if (t.data.size() > 0){
                            position := t.data[0].position;
                            avgPrice := t.data[0].avgPrice;
                        };
                        if (position != 0){
                            switch(_getCompetitionClosedPrice(_round, t.pair)){
                                case(?(lastPrice, priceTime)){
                                    closedPrice := lastPrice;
                                    pnl += Float.fromInt(position) * (lastPrice - avgPrice);
                                };
                                case(_){};
                            };
                        };
                        return {
                            dexName = t.dexName;
                            pair = t.pair;
                            quoteToken =  t.quoteToken;
                            startTime = t.startTime;
                            data = t.data;
                            endTime = if (_settle) { ?time }else{ null };
                            total = ?({
                                time = time;
                                position = position; // position;
                                avgPrice = avgPrice; // avgPrice;
                                capital = capital;
                                vol = vol;
                                pnl = pnl; // Notes: Realized P&L and unrealized P&L
                                count = count; 
                                trades = []; 
                            }, closedPrice);
                        };
                    }else{
                        return t;
                    };
                });
                dexCompetitionTraders := Trie.put2D(dexCompetitionTraders, keyn(_round), Nat.equal, keyb(_a), Blob.equal, newItems);
            };
            case(_){};
        };
    };
    private func _tradeParse(quoteToken: {#token0; #token1}, position: Int, trade: FilledTrade): [TradeParse]{
        var newPosition = position;
        var positionChange: Int = 0;
        var amountChange: Int = 0;
        var positionDirection: {#long; #short} = #long;
        var tradeType: {#open; #close} = #open;
        var backhand: Bool = false;
        var positionChange2: Int = 0;
        var amountChange2: Int = 0;
        var positionDirection2: {#long; #short} = #long;
        var tradeType2: {#open; #close} = #open;
        if (quoteToken == #token1){
            var amountChange0 : Int = 0;
            switch(trade.token1Value, trade.token0Value){
                case(#DebitRecord(amount), #CreditRecord(v)){ // Buy
                    amountChange0 := 0 - amount;
                    newPosition := position + v;
                    positionChange := v;
                    amountChange := amountChange0; // -
                    if (position >= 0){
                        positionDirection := #long;
                        tradeType := #open;
                        backhand := false;
                    }else if (newPosition <= 0){
                        positionDirection := #short;
                        tradeType := #close;
                        backhand := false;
                    }else if (position < 0 and newPosition > 0){
                        positionChange := 0 - position;
                        amountChange := amountChange0 * Int.abs(position) / v;
                        positionDirection := #short;
                        tradeType := #close;
                        backhand := true;
                        positionChange2 := newPosition;
                        amountChange2 := amountChange0 * newPosition / v;
                        positionDirection2 := #long;
                        tradeType2 := #open;
                    };
                }; 
                case(#CreditRecord(amount), #DebitRecord(v)){ // Sell
                    amountChange0 := amount;
                    newPosition := position - v;
                    positionChange := 0 - v;
                    amountChange := amountChange0; // +
                    if (newPosition >= 0){
                        positionDirection := #long;
                        tradeType := #close;
                        backhand := false;
                    }else if (position <= 0){
                        positionDirection := #short;
                        tradeType := #open;
                        backhand := false;
                    }else if (position > 0 and newPosition < 0){
                        positionChange := 0 - position;
                        amountChange := amountChange0 * position / v;
                        positionDirection := #long;
                        tradeType := #close;
                        backhand := true;
                        positionChange2 := newPosition;
                        amountChange2 := amountChange0 * Int.abs(newPosition) / v;
                        positionDirection2 := #short;
                        tradeType2 := #open;
                    };
                };
                case(_, _){};
            };
        }else{ // #token0
            var amountChange0 : Int = 0;
            switch(trade.token0Value, trade.token1Value){
                case(#DebitRecord(amount), #CreditRecord(v)){ // Buy
                    amountChange0 := 0 - amount;
                    newPosition := position + v;
                    positionChange := v;
                    amountChange := amountChange0; // -
                    if (position >= 0){
                        positionDirection := #long;
                        tradeType := #open;
                        backhand := false;
                    }else if (newPosition <= 0){
                        positionDirection := #short;
                        tradeType := #close;
                        backhand := false;
                    }else if (position < 0 and newPosition > 0){
                        positionChange := 0 - position;
                        amountChange := amountChange0 * Int.abs(position) / v;
                        positionDirection := #short;
                        tradeType := #close;
                        backhand := true;
                        positionChange2 := newPosition;
                        amountChange2 := amountChange0 * newPosition / v;
                        positionDirection2 := #long;
                        tradeType2 := #open;
                    };
                }; 
                case(#CreditRecord(amount), #DebitRecord(v)){ // Sell
                    amountChange0 := amount;
                    newPosition := position - v;
                    positionChange := 0 - v;
                    amountChange := amountChange0; // +
                    if (newPosition >= 0){
                        positionDirection := #long;
                        tradeType := #close;
                        backhand := false;
                    }else if (position <= 0){
                        positionDirection := #short;
                        tradeType := #open;
                        backhand := false;
                    }else if (position > 0 and newPosition < 0){
                        positionChange := 0 - position;
                        amountChange := amountChange0 * position / v;
                        positionDirection := #long;
                        tradeType := #close;
                        backhand := true;
                        positionChange2 := newPosition;
                        amountChange2 := amountChange0 * Int.abs(newPosition) / v;
                        positionDirection2 := #short;
                        tradeType2 := #open;
                    };
                };
                case(_, _){};
            };
        };
        if (backhand){
            return [{
                positionChange = positionChange;
                amountChange = amountChange;
                positionDirection = positionDirection;
                tradeType = tradeType;
            }, {
                positionChange = positionChange2;
                amountChange = amountChange2;
                positionDirection = positionDirection2;
                tradeType = tradeType2;
            }];
        }else{
            return [{
                positionChange = positionChange;
                amountChange = amountChange;
                positionDirection = positionDirection;
                tradeType = tradeType;
            }];
        };
    };
    private func _fetchDexCompetitionData(_round: ?Nat) : async* (){
        let roundId = Option.get(_round, dexCompetitionIndex);
        switch(Trie.get(dexCompetitions, keyn(roundId), Nat.equal)){
            case(?(comp)){ /* debug */
                // if (Time.now() < comp.end and Time.now() < _fetchDexCompetitionDataTime + 4*3600*1000000000){ // Interval should be greater than 4h
                //     return ();
                // }else if (Time.now() < _fetchDexCompetitionDataTime + 5*60*1000000000){ // Interval should be greater than 5m
                //     return ();
                // };
                _fetchDexCompetitionDataTime := Time.now(); 
                switch(Trie.get(dexCompetitionTraders, keyn(roundId), Nat.equal)){
                    case(?(traders)){
                        for ((account, items) in Trie.iter(traders)){
                            label FetchPairData for (pairData in items.vals()){
                                if (Option.isSome(pairData.endTime)){
                                    continue FetchPairData;
                                };
                                let quoteToken = pairData.quoteToken;
                                var startTime = pairData.startTime;
                                var position : Int = 0;
                                var avgPrice : Float = 0;
                                var capital : Float = 0;
                                var vol : Nat = 0;
                                var pnl : Float = 0;
                                var count : Nat = 0;
                                let pair: DRC205T.Impl = actor(Principal.toText(pairData.pair));
                                if (pairData.data.size() > 0){
                                    startTime := pairData.data[0].time + 1;
                                    position := pairData.data[0].position;
                                    avgPrice := pairData.data[0].avgPrice;
                                };
                                // let txs = await pair.drc205_events(?Hex.encode(Blob.toArray(account)));
                                let (txs, hasMorePreData) = await pair.drc205_events_filter(?Hex.encode(Blob.toArray(account)), ?startTime, null); // Time DESC
                                var filledTrades: [FilledTrade] = [];
                                var lastTime = startTime;
                                var txCount: Nat = 0;
                                for (tx in Array.reverse(txs).vals()){
                                    txCount += 1;
                                    for (trade in tx.details.vals()){
                                        if (trade.time >= startTime){
                                            lastTime := Int.max(lastTime, trade.time);
                                            filledTrades := Tools.arrayAppend(filledTrades, [trade]); // Time ASC
                                        };
                                    };
                                };
                                filledTrades := Array.sort(filledTrades, func (a:FilledTrade, b:FilledTrade): Order.Order{
                                    Int.compare(a.time, b.time) // Time ASC
                                });
                                for (trade in filledTrades.vals()){
                                    for (detail in _tradeParse(quoteToken, position, trade).vals()){
                                        if (detail.tradeType == #open){
                                            avgPrice := (Float.fromInt(Int.abs(position)) * avgPrice + Float.fromInt(Int.abs(detail.amountChange))) / Float.fromInt(Int.abs(position + detail.positionChange));
                                            position += detail.positionChange;
                                            capital := Float.max(capital, Float.fromInt(Int.abs(position)) * avgPrice);
                                            vol += Int.abs(detail.amountChange);
                                            count += 1;
                                        }else if (detail.tradeType == #close){
                                            if (detail.positionDirection == #long){
                                                pnl += Float.fromInt(Int.abs(detail.positionChange)) * (Float.fromInt(Int.abs(detail.amountChange)) / Float.fromInt(Int.abs(detail.positionChange)) - avgPrice); 
                                            }else{
                                                pnl += Float.fromInt(Int.abs(detail.positionChange)) * (avgPrice - Float.fromInt(Int.abs(detail.amountChange)) / Float.fromInt(Int.abs(detail.positionChange)));
                                            };
                                            if (position + detail.positionChange == 0){
                                                avgPrice := 0;
                                            };
                                            position += detail.positionChange;
                                            capital := Float.max(capital, Float.fromInt(Int.abs(position)) * avgPrice);
                                            vol += Int.abs(detail.amountChange);
                                            count += 1;
                                        };
                                    };
                                };
                                if (filledTrades.size() > 0){
                                    let newStats: TraderStats = { 
                                        time = lastTime;
                                        position = position;
                                        avgPrice = avgPrice; 
                                        capital = capital; 
                                        vol = vol; 
                                        pnl = pnl; 
                                        count = count; 
                                        trades = filledTrades; 
                                    };
                                    _updateCompetitionTrader(roundId, account, pairData.pair, newStats);
                                };
                                // High Frequency Trader (txCount >= 500)
                                if (pairData.data.size() > 0 and hasMorePreData and txCount >= 500){
                                    await* _aggregateCompetitionTrader(roundId, account, true); // settle & drop competition
                                };
                            };
                            await* _aggregateCompetitionTrader(roundId, account, Time.now() > comp.end); // settle competition
                        };
                    };
                    case(_){};
                };
            };
            case(_){};
        };
    };

    public shared(msg) func pushCompetitionByDex(_id: ?Nat, _name: Text, _content: Text, _start: Time.Time, _end: Time.Time, _addPairs: [(DexName, Principal, {#token0; #token1})]) : async Nat{
        assert(_onlyDexList(msg.caller));
        let hostedDexName = _getDexName(msg.caller);
        var pairs: [(DexName, Principal, {#token0;#token1})] = [];
        for ((dex, pair, quoteToken) in _addPairs.vals()){
            if (_inDexList(dex) and _onlyPair(pair)){
                pairs := Tools.arrayAppend(pairs, [(dex, pair, quoteToken)]);
            };
        };
        switch(_id){ 
            case(?(id)){
                switch(Trie.get(dexCompetitions, keyn(id), Nat.equal)){
                    case(?(competition)){
                        dexCompetitions := Trie.put(dexCompetitions, keyn(id), Nat.equal, {
                            hostedDex = hostedDexName;
                            name = (if (Text.size(_name) > 0){ _name }else{ competition.name });
                            content = (if (Text.size(_content) > 0){ _content }else{ competition.content });
                            start = (if (_start > 0){ _start }else{ competition.start });
                            end = (if (_end > 0){ _end }else{ competition.end });
                            pairs = pairs
                        }).0;
                    };
                    case(_){ assert(false) };
                };
                return id;
            };
            case(_){
                dexCompetitionIndex += 1;
                dexCompetitions := Trie.put(dexCompetitions, keyn(dexCompetitionIndex), Nat.equal, {
                    hostedDex = hostedDexName;
                    name = _name;
                    content = _content;
                    start = _start;
                    end = _end;
                    pairs = pairs
                }).0;
                return dexCompetitionIndex;
            };
        };
    };
    public query func getDexCompetitions(_hostedDex: ?DexName, _page: ?Nat, _size: ?Nat) : async TrieList<Nat, DexCompetitionResponse>{
        var trie : Trie.Trie<Nat, DexCompetitionResponse> = Trie.empty();
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        trie := Trie.mapFilter(dexCompetitions, func (k:Nat, v:DexCompetition): ?DexCompetitionResponse { 
            let pairList: [(DexName, PairInfo, {#token0;#token1})] = 
            Array.mapFilter<(DexName, Principal, {#token0;#token1}),(DexName, PairInfo, {#token0;#token1})>(v.pairs, func (t: (DexName, Principal, {#token0;#token1})): ?(DexName, PairInfo, {#token0;#token1}){
                switch(Trie.get(tradingPairs, keyp(t.1), Principal.equal)){
                    case(?(pair)){ ?(t.0, pair.pair, t.2) };
                    case(_){ null };
                };
            });
            return ?{
                hostedDex = v.hostedDex;
                name = v.name;
                content = v.content;
                start = v.start;
                end = v.end;
                pairs = pairList;
            };
        });
        return trieItems(trie, page, size);
    };
    public query func getDexCompetition(_round: Nat) : async ?DexCompetitionResponse{
        switch(Trie.get(dexCompetitions, keyn(_round), Nat.equal)){
            case(?v){
                let pairList: [(DexName, PairInfo, {#token0;#token1})] = Array.mapFilter<(DexName, Principal, {#token0;#token1}),(DexName, PairInfo, {#token0;#token1})>(v.pairs, func (t: (DexName, Principal, {#token0;#token1})): ?(DexName, PairInfo, {#token0;#token1}){
                    switch(Trie.get(tradingPairs, keyp(t.1), Principal.equal)){
                        case(?(pair)){ ?(t.0, pair.pair, t.2) };
                        case(_){ null };
                    };
                });
                return ?{
                    hostedDex = v.hostedDex;
                    name = v.name;
                    content = v.content;
                    start = v.start;
                    end = v.end;
                    pairs = pairList;
                };
            };
            case(_){ return null };
        };
    };
    public query func getDexCompetitionRound(): async Nat{
        return dexCompetitionIndex;
    };
    public query func getDexCompetitionTraders(_round: Nat, _page: ?Nat, _size: ?Nat) : async TrieList<AccountId, [TraderDataResponse]>{
        var traders : Trie.Trie<AccountId, [TraderDataResponse]> = Trie.empty();
        let page = Option.get(_page, 1);
        let size = Option.get(_size, 100);
        switch(Trie.get(dexCompetitionTraders, keyn(_round), Nat.equal)){
            case(?(data)){
                traders := Trie.mapFilter(data, func (k:AccountId, v:[TraderData]): ?[TraderDataResponse] { 
                    return ?Array.mapFilter<TraderData, TraderDataResponse>(v, 
                        func (t: TraderData): ?TraderDataResponse{
                            switch(Trie.get(tradingPairs, keyp(t.pair), Principal.equal)){
                                case(?(pair)){ ?{
                                    pair = pair.pair;
                                    quoteToken = t.quoteToken;
                                    startTime = t.startTime;
                                    endTime = t.endTime;
                                    data = [];
                                    total = t.total;
                                } };
                                case(_){ null };
                            };
                    });
                });
            };
            case(_){};
        };
        return trieItems(traders, page, size);
    };
    public query func getDexCompetitionTrader(_round: Nat, _a: Address): async ?[TraderData]{
        return _getCompetitionTrader(_round, _getAccountId(_a));
    };
    public shared(msg) func registerDexCompetition(_sa: ?[Nat8]): async Bool{
        // assert(Tools.principalForm(msg.caller) == #OpaqueId); // Trader Canister 
        let account = Tools.principalToAccountBlob(msg.caller, _sa);
        let round = dexCompetitionIndex;
        switch(Trie.get(dexCompetitions, keyn(round), Nat.equal)){
            case(?(competition)){
                if (Time.now() < competition.start or Time.now() > competition.end){
                    return false;
                };
                // switch(_findNFT(account, null, true)){
                //     case(?nft){
                //         _stake(account, "DexCompetition", nft.1, competition.end - Time.now());
                //     };
                //     case(_){
                //         return false;
                //     };
                // };
                switch(_getCompetitionTrader(round, account)){
                    case(?(traderData)){ return false };
                    case(_){
                        var traderData : [TraderData] = [];
                        for ((dexName, canisterId, quoteToken) in competition.pairs.vals()){
                            traderData := Tools.arrayAppend(traderData, [{
                                dexName = dexName;
                                pair = canisterId;
                                quoteToken = quoteToken;
                                startTime = Time.now();
                                endTime = null;
                                data = [];
                                total = null;
                                trades = [];
                            }]);
                        };
                        dexCompetitionTraders := Trie.put2D(dexCompetitionTraders, keyn(round), Nat.equal, keyb(account), Blob.equal, traderData);
                    };
                };
            };
            case(_){ return false };
        };
        return true;
    };
    public shared(msg) func debug_fetchCompData(_round: ?Nat): async (){
        assert(_onlyOwner(msg.caller));
        await* _fetchDexCompetitionData(_round);
    };
    // public query func getCompetitions(_dexName: ?DexName, _page: ?Nat, _size: ?Nat) : async TrieList<PairCanisterId, {pair:PairResponse; round: Nat; name: Text; start: Time.Time; end: Time.Time}>{
    //     var trie : Trie.Trie<PairCanisterId, {pair:PairResponse; round: Nat; name: Text; start: Time.Time; end: Time.Time}> = Trie.empty();
    //     let page = Option.get(_page, 1);
    //     let size = Option.get(_size, 100);
    //     trie := Trie.mapFilter(competitions, func (k:PairCanisterId, v:(round: Nat, name: Text, start: Time.Time, end: Time.Time)): 
    //     ?{pair:PairResponse; round: Nat; name: Text; start: Time.Time; end: Time.Time} { 
    //         switch(_getPairResponse(_dexName, null, k)){
    //             case(?(response)){ 
    //                 if (Time.now() < v.3 + 365*24*3600*1000000000){
    //                     return ?{pair = response; round = v.0; name = v.1; start = v.2; end = v.3};
    //                 }else{ return null; };
    //             };
    //             case(_){ return null; };
    //         };
    //     });
    //     return trieItems(trie, page, size);
    // };
    // End: DexCompetitions


    /* =======================
      NFT
    ========================= */
    // private stable var nftVipMakers: Trie.Trie<Text, (AccountId, [Principal])> = Trie.empty(); 
    type NFTType = {#NEPTUNE/*0-4*/; #URANUS/*5-14*/; #SATURN/*15-114*/; #JUPITER/*115-314*/; #MARS/*315-614*/; #EARTH/*615-1014*/; #VENUS/*1015-1514*/; #MERCURY/*1515-2021*/; #UNKNOWN};
    type CollectionId = Principal;
    type NFT = (ERC721.User, ERC721.TokenIdentifier, ERC721.Balance, NFTType, CollectionId);
    private stable var nfts: Trie.Trie<AccountId, [NFT]> = Trie.empty();
    private let sa_zero : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    private let nftPlanetCards: Principal = Principal.fromText("goncb-kqaaa-aaaap-aakpa-cai"); // ICLighthouse Planet Cards
    private func _onlyNFTHolder(_owner: AccountId, _nftId: ?ERC721.TokenIdentifier, _nftType: ?NFTType) : Bool{
        switch(Trie.get(nfts, keyb(_owner), Blob.equal), _nftId, _nftType){
            case(?(items), null, null){ return items.size() > 0 };
            case(?(items), ?(nftId), ?(nftType)){
                switch(Array.find(items, func(t: NFT): Bool{ nftId == t.1 and nftType == t.3 and t.2 > 0 })){
                    case(?(user, nftId, balance, nType, collId)){ return balance > 0 };
                    case(_){};
                };
            };
            case(?(items), ?(nftId), null){
                switch(Array.find(items, func(t: NFT): Bool{ nftId == t.1 and t.2 > 0 })){
                    case(?(user, nftId, balance, nType, collId)){ return balance > 0 };
                    case(_){};
                };
            };
            case(?(items), null, ?(nftType)){
                switch(Array.find(items, func(t: NFT): Bool{ nftType == t.3 and t.2 > 0 })){
                    case(?(user, nftId, balance, nType, collId)){ return balance > 0 };
                    case(_){};
                };
            };
            case(_, _, _){};
        };
        return false;
    };
    private func _nftType(_a: ?AccountId, _nftId: Text): NFTType{
        switch(_a){
            case(?(accountId)){
                switch(Trie.get(nfts, keyb(accountId), Blob.equal)){
                    case(?(items)){ 
                        switch(Array.find(items, func(t: NFT): Bool{ _nftId == t.1 })){
                            case(?(user, nftId, balance, nftType, collId)){ return nftType };
                            case(_){};
                        };
                    };
                    case(_){};
                };
            };
            case(_){
                for ((accountId, items) in Trie.iter(nfts)){
                    switch(Array.find(items, func(t: NFT): Bool{ _nftId == t.1 })){
                        case(?(user, nftId, balance, nftType, collId)){ return nftType };
                        case(_){};
                    };
                };
            };
        };
        return #UNKNOWN;
    };
    private func _remote_nftType(_collId: CollectionId, _nftId: Text): async* NFTType{
        if (_collId == nftPlanetCards){
            let nft: ERC721.Self = actor(Principal.toText(_collId));
            let metadata = await nft.metadata(_nftId);
            switch(metadata){
                case(#ok(#nonfungible({metadata=?(data)}))){
                    if (data.size() > 0){
                        switch(Text.decodeUtf8(data)){
                            case(?(json)){
                                let str = Text.replace(json, #char(' '), "");
                                if (Text.contains(str, #text("\"name\":\"NEPTUNE")) or Text.contains(str, #text("name:\"NEPTUNE"))){
                                    return #NEPTUNE;
                                }else if (Text.contains(str, #text("\"name\":\"URANUS")) or Text.contains(str, #text("name:\"URANUS"))){
                                    return #URANUS;
                                }else if (Text.contains(str, #text("\"name\":\"SATURN")) or Text.contains(str, #text("name:\"SATURN"))){
                                    return #SATURN;
                                }else if (Text.contains(str, #text("\"name\":\"JUPITER")) or Text.contains(str, #text("name:\"JUPITER"))){
                                    return #JUPITER;
                                }else if (Text.contains(str, #text("\"name\":\"MARS")) or Text.contains(str, #text("name:\"MARS"))){
                                    return #MARS;
                                }else if (Text.contains(str, #text("\"name\":\"EARTH")) or Text.contains(str, #text("name:\"EARTH"))){
                                    return #EARTH;
                                }else if (Text.contains(str, #text("\"name\":\"VENUS")) or Text.contains(str, #text("name:\"VENUS"))){
                                    return #VENUS;
                                }else if (Text.contains(str, #text("\"name\":\"MERCURY")) or Text.contains(str, #text("name:\"MERCURY"))){
                                    return #MERCURY;
                                };
                            };
                            case(_){};
                        };
                    };
                };
                case(_){};
            };
        };
        return #UNKNOWN;
    };
    private func _remote_isNftHolder(_collId: CollectionId, _a: AccountId, _nftId: Text) : async* Bool{
        let nft: ERC721.Self = actor(Principal.toText(_collId));
        let balance = await nft.balance({ user = #address(_accountIdToHex(_a)); token = _nftId; });
        switch(balance){
            case(#ok(amount)){ return amount > 0; };
            case(_){ return false; };
        };
    };
    private func _NFTPut(_a: AccountId, _nft: NFT) : (){
        switch(Trie.get(nfts, keyb(_a), Blob.equal)){
            case(?(items)){ 
                let _items = Array.filter(items, func(t: NFT): Bool{ t.1 != _nft.1 });
                nfts := Trie.put(nfts, keyb(_a), Blob.equal, Tools.arrayAppend(_items, [_nft])).0 
            };
            case(_){ 
                nfts := Trie.put(nfts, keyb(_a), Blob.equal, [_nft]).0 
            };
        };
    };
    private func _NFTRemove(_a: AccountId, _nftId: ERC721.TokenIdentifier) : (){
        switch(Trie.get(nfts, keyb(_a), Blob.equal)){
            case(?(items)){ 
                let _items = Array.filter(items, func(t: NFT): Bool{ t.1 != _nftId });
                if (_items.size() > 0){
                    nfts := Trie.put(nfts, keyb(_a), Blob.equal, _items).0;
                }else{
                    nfts := Trie.remove(nfts, keyb(_a), Blob.equal).0;
                };
            };
            case(_){};
        };
    };
    private func _NFTTransferFrom(_caller: Principal, _collId: CollectionId, _nftId: ERC721.TokenIdentifier, _sa: ?[Nat8]) : async* ERC721.TransferResponse{
        let accountId = Tools.principalToAccountBlob(_caller, _sa);
        var user: ERC721.User = #principal(_caller);
        if (Option.isSome(_sa) and _sa != ?sa_zero){
            user := #address(Tools.principalToAccountHex(_caller, _sa));
        };
        let nftActor: ERC721.Self = actor(Principal.toText(_collId));
        let args: ERC721.TransferRequest = {
            from = user;
            to = #principal(Principal.fromActor(this));
            token = _nftId;
            amount = 1;
            memo = Blob.fromArray([]);
            notify = false;
            subaccount = null;
        };
        let nftType = await* _remote_nftType(_collId, _nftId);
        let res = await nftActor.transfer(args);
        switch(res){
            case(#ok(v)){ 
                _NFTPut(accountId, (user, _nftId, v, nftType, _collId));
            };
            case(_){};
        };
        return res;
    };
    private func _NFTWithdraw(_caller: Principal, _nftId: ?ERC721.TokenIdentifier, _sa: ?[Nat8]) : async* (){
        let accountId = Tools.principalToAccountBlob(_caller, _sa);
        // Hooks used to check binding
        assert(not(_onlyNFTStakedByNftId(accountId, _nftId, 0)));
        switch(Trie.get(nfts, keyb(accountId), Blob.equal)){
            case(?(item)){ 
                for(nft in item.vals()){
                    let nftActor: ERC721.Self = actor(Principal.toText(nft.4));
                    let args: ERC721.TransferRequest = {
                        from = #principal(Principal.fromActor(this));
                        to = nft.0;
                        token = nft.1;
                        amount = nft.2;
                        memo = Blob.fromArray([]);
                        notify = false;
                        subaccount = null;
                    };
                    switch(await nftActor.transfer(args)){
                        case(#ok(balance)){
                            _NFTRemove(accountId, nft.1);
                            // Hooks used to unbind all
                            _dropListingReferrer(_caller);
                        };
                        case(#err(e)){};
                    };
                };
             };
            case(_){};
        };
    };
    public query func NFTs() : async [(AccountId, [NFT])]{
        return Trie.toArray<AccountId, [NFT], (AccountId, [NFT])>(nfts, func (k:AccountId, v:[NFT]) : (AccountId, [NFT]){  (k, v) });
    };
    public query func NFTBalance(_owner: Address) : async [NFT]{
        let accountId = _getAccountId(_owner);
        switch(Trie.get(nfts, keyb(accountId), Blob.equal)){
            case(?(items)){ return items };
            case(_){ return []; };
        };
    };
    public shared(msg) func NFTDeposit(_collectionId: CollectionId, _nftId: ERC721.TokenIdentifier, _sa: ?[Nat8]) : async (){
        let r = await* _NFTTransferFrom(msg.caller, _collectionId, _nftId, _sa);
    };
    public shared(msg) func NFTWithdraw(_nftId: ?ERC721.TokenIdentifier, _sa: ?[Nat8]) : async (){
        let accountId = Tools.principalToAccountBlob(msg.caller, _sa);
        assert(_onlyNFTHolder(accountId, _nftId, null));
        await* _NFTWithdraw(msg.caller, _nftId, _sa);
    };

    /* ===== functions for Specific Permissions ==== */
    type StakedNFT = (name: Text, nftId: ERC721.TokenIdentifier, unlockTime: Time.Time);
    private stable var nftStaked: Trie.Trie<AccountId, [StakedNFT]> = Trie.empty(); // Locked
    private func _nftIndexToId(_collId: CollectionId, _index: ERC721.TokenIndex): ERC721.TokenIdentifier{
        var data: [Nat8] = [10,116,105,100]; // \x0Atid
        data := Tools.arrayAppend(data, Blob.toArray(Principal.toBlob(_collId)));
        data := Tools.arrayAppend(data, Binary.BigEndian.fromNat32(_index));
        return Principal.toText(Principal.fromBlob(Blob.fromArray(data)));
    };
    private func _findNFT(_owner: AccountId, _nftType: ?NFTType, _shouldNotStaked: Bool) : ?NFT{
        switch(Trie.get(nfts, keyb(_owner), Blob.equal), _nftType, _shouldNotStaked){
            case(?(items), ?nftType, true){ return Array.find(items, func (t: NFT): Bool{ t.3 == nftType and not(_onlyNFTStakedByNftId(_owner, ?t.1, 0)) }); };
            case(?(items), ?nftType, false){ return Array.find(items, func (t: NFT): Bool{ t.3 == nftType }); };
            case(?(items), _, true){ if (items.size() > 0){ return Array.find(items, func (t: NFT): Bool{ not(_onlyNFTStakedByNftId(_owner, ?t.1, 0)) }); }else { return null } };
            case(?(items), _, false){ if (items.size() > 0){ return ?items[0] }else { return null } };
            case(_){ return null; };
        };
    };
    private func _onlyNFTStakedByNftId(_owner: AccountId, _nftId: ?ERC721.TokenIdentifier, _minPeriod: Time.Time) : Bool{
        switch(Trie.get(nftStaked, keyb(_owner), Blob.equal)){
            case(?(items)){ 
                for ((name, nftId, time) in items.vals()){
                    switch(_nftId){
                        case(?(id)){ if (id == nftId and Time.now() + _minPeriod <= time){ return true }  };
                        case(_){ if (Time.now() + _minPeriod <= time){ return true } };
                    };
                };
                return false;
            };
            case(_){ return false };
        };
    };
    private func _onlyNFTStaked(_owner: AccountId, _name: ?Text, _minPeriod: Time.Time) : Bool{
        switch(Trie.get(nftStaked, keyb(_owner), Blob.equal)){
            case(?(items)){ 
                for ((name, nftId, time) in items.vals()){
                    switch(_name){
                        case(?(n)){ if (n == name and Time.now() + _minPeriod <= time){ return true }  };
                        case(_){ if (Time.now() + _minPeriod <= time){ return true } };
                    };
                };
                return false;
            };
            case(_){ return false };
        };
    };
    private func _stake(_owner: AccountId, _name: Text, _nftId: ERC721.TokenIdentifier, _lockPeriod: Time.Time) : (){
        var _unLockTime : Time.Time = Time.now() + _lockPeriod;
        assert(_onlyNFTHolder(_owner, ?_nftId, null));
        switch(Trie.get(nftStaked, keyb(_owner), Blob.equal)){
            case(?(items)){
                switch(Array.find(items, func (t: StakedNFT): Bool{ t.0 == _name and Time.now() < t.2 })){
                    case(?item){ _unLockTime := item.2 + _lockPeriod };
                    case(_){};
                };
                if (_name == "ListingReferrer"){
                    assert(_unLockTime - Time.now() <= 360 * 24 * 3600 * 1000000000);
                };
                var newItems = Array.filter(items, func (t: StakedNFT): Bool{ t.0 != _name and Time.now() < t.2 });
                newItems := Tools.arrayAppend(newItems, [(_name, _nftId, _unLockTime)]);
                nftStaked := Trie.put(nftStaked, keyb(_owner), Blob.equal, newItems).0;
            };
            case(_){
                nftStaked := Trie.put(nftStaked, keyb(_owner), Blob.equal, [(_name, _nftId, _unLockTime)]).0;
            };
        };
    };
    private func _unStake(_owner: AccountId, _name: Text) : (){
        assert(_onlyNFTStaked(_owner, ?_name, 0));
        switch(Trie.get(nftStaked, keyb(_owner), Blob.equal)){
            case(?(items)){
                let newItems = Array.filter(items, func (t: StakedNFT): Bool{ t.0 != _name and Time.now() < t.2 });
                if (newItems.size() > 0){
                    nftStaked := Trie.put(nftStaked, keyb(_owner), Blob.equal, newItems).0;
                }else{
                    nftStaked := Trie.remove(nftStaked, keyb(_owner), Blob.equal).0;
                };
            };
            case(_){};
        };
    };
    public shared(msg) func NFTUnStake(_accountId: AccountId, _permissionName: Text) : async (){
        assert(_onlyOwner(msg.caller));
        _unStake(_accountId, _permissionName);
    };
    public query func NFTStakedList(): async [(AccountId, [StakedNFT])]{
        return Trie.toArray<AccountId, [StakedNFT], (AccountId, [StakedNFT])>(nftStaked, func (k:AccountId, v:[StakedNFT]) : (AccountId, [StakedNFT]){
            (k, Array.filter(v, func (t: StakedNFT): Bool{ Time.now() < t.2 })) }
        );
    };
    public query func NFTStaked(_owner: Address) : async [StakedNFT]{
        let accountId = _getAccountId(_owner);
        switch(Trie.get(nftStaked, keyb(accountId), Blob.equal)){
            case(?(items)){ return Array.filter(items, func (t: StakedNFT): Bool{ Time.now() < t.2 }); };
            case(_){ return []; };
        };
    };
    // End: NFTs

    /* =====================
      DRC207
    ====================== */
    /// DRC207 support
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = ?setting.BLACKHOLE; };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = ?(4*3600); }; 
        };
    };
    // /// canister_status
    // public func canister_status() : async DRC207.canister_status {
    //     let ic : DRC207.IC = actor("aaaaa-aa");
    //     await ic.canister_status({ canister_id = Principal.fromActor(this) });
    // };
    /// receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };
    /// timer tick
    // public func timer_tick(): async (){
    //     let f = monitor();
    // };

    /* =====================
      Timer
    ====================== */
    private var competitionTimerId: Nat = 0;
    private var competitionTimerInterval: Nat = 4*3600; // seconds  /* debug */
    private func competitionTask() : async (){
        let now: Nat = Int.abs(Time.now() / 1000000000);
        let tid: Nat = now / competitionTimerInterval;
        await* _fetchDexCompetitionData(null);
        competitionTimerId := Timer.setTimer(#seconds((tid+1)*competitionTimerInterval - now + 1), competitionTask);
    };
    
    private var timerId: Nat = 0;
    private var isTimerDoing: Bool = false;
    private var lastTimerExcuting: Timestamp = 0;
    private func timerLoop() : async (){
        if (not(isTimerDoing) or _now() > lastTimerExcuting + 12 * 3600){
            isTimerDoing := true;
            lastTimerExcuting := _now();
            if (competitionTimerId == 0){
                let now: Nat = Int.abs(Time.now() / 1000000000);
                let tid: Nat = now / competitionTimerInterval;
                competitionTimerId := Timer.setTimer(#seconds((tid+1)*competitionTimerInterval - now + 1), competitionTask);
            };
            try{ await* _fetchOracleFeed() }catch(e){};
            try{ await* _updateLiquidity() }catch(e){};
            isTimerDoing := false;
        };
    };
    public shared(msg) func timerStart(_intervalSeconds: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        timerId := Timer.recurringTimer(#seconds(_intervalSeconds), timerLoop);
    };
    public shared(msg) func timerStop(): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
    };

    /* =====================
      Upgrade
    ====================== */
    system func preupgrade() {
        Timer.cancelTimer(timerId);
        Timer.cancelTimer(competitionTimerId);
    };
    system func postupgrade() {
        timerId := Timer.recurringTimer(#seconds(600), timerLoop);
        let now: Nat = Int.abs(Time.now() / 1000000000);
        let tid: Nat = now / competitionTimerInterval;
        competitionTimerId := Timer.setTimer(#seconds((tid+1)*competitionTimerInterval - now + 1), competitionTask);

        // for ((canisterId, (pair, score)) in Trie.iter(pairs)){
        //     _autoPutMarket(pair);
        // };

        if (Trie.size(tradingPairs) == 0){
            for ((canisterId, (pair, score)) in Trie.iter(pairs)){
                tradingPairs := Trie.put(tradingPairs, keyp(canisterId), Principal.equal, {
                    pair = pair;
                    marketBoard = #STAGE1;
                    score1 = 0;
                    score2 = 0;
                    score3 = 0;
                    startingOverG1 = null;
                    startingBelowG2 = null;
                    startingBelowG4 = null;
                    createdTime = _now();
                    updatedTime = _now();
                }).0;
            };
        };

    };

};