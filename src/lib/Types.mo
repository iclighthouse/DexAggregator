import Time "mo:base/Time";
import Result "mo:base/Result";
import DRC205 "mo:icl/DRC205Types";
import ICDex "mo:icl/ICDexTypes";

module {
    public type Timestamp = Nat;
    public type DexName = Text;
    public type TokenStd = DRC205.TokenStd; // #cycles token principal = CF canister
    public type TokenSymbol = Text;
    public type TokenInfo = (Principal, TokenSymbol, TokenStd);
    public type ListingReferrer = {
        referrer: Principal;
        name: Text;
        verified: Bool;
        start: Time.Time;
        end: ?Time.Time;
        nftId: Text;
    };
    public type MarketBoard = { #STAGE2; #STAGE1; #STAGE0 };
    public type TradingPair = {
        pair: PairInfo;
        marketBoard: MarketBoard;
        score1: Nat; // Max 70
        score2: Nat; // Max 20
        score3: Nat;
        startingOverG1: ?Timestamp;
        startingBelowG2: ?Timestamp;
        startingBelowG4: ?Timestamp;
        createdTime: Timestamp;
        updatedTime: Timestamp;
    };
    public type PairCanister = Principal;
    public type PairRequest = {
        token0: TokenInfo; 
        token1: TokenInfo; 
        dexName: DexName; 
    };
    public type PairInfo = {
        token0: TokenInfo; 
        token1: TokenInfo; 
        dexName: DexName; 
        canisterId: PairCanister;
        feeRate: Float; 
    };
    public type PairResponse = { 
        pair: PairInfo; 
        score: Nat; 
        createdTime: Timestamp;
        liquidity: ?ICDex.Liquidity2; 
        sponsored: Bool; 
        listingReferrers: [(ListingReferrer, Time.Time, Text)];
    };
    public type Txid = Blob;
    public type AccountId = Blob;
    public type Nonce = Nat;
    public type Address = Text;
    public type TxnStatus = { #Pending; #Success; #Failure; #Blocking; };
    public type TxnResult = Result.Result<{   //<#ok, #err> 
        txid: Txid;
        status: TxnStatus;
    }, {
        code: Nat;
        message: Text;
    }>;
    public type DexCompetition = {
        hostedDex: DexName;
        name: Text;
        content: Text;
        start: Time.Time;
        end: Time.Time;
        pairs: [(DexName, Principal, {#token0; #token1})]
    };
    public type DexCompetitionResponse = {
        hostedDex: DexName;
        name: Text;
        content: Text;
        start: Time.Time;
        end: Time.Time;
        pairs: [(DexName, PairInfo, {#token0; #token1})]
    };
    public type FilledTrade = {counterparty: Txid; token0Value: DRC205.BalanceChange; token1Value: DRC205.BalanceChange; time: Time.Time;};
    public type TraderStats = { // Measured in quote token, data[0] is the latest data
        time: Time.Time; // latest trade time
        position: Int; // +: long; -: short
        avgPrice: Float; // 1 smallest token = ? smallest quote_token
        capital: Float; // max(abs(holding) * price)
        vol: Nat; // (smallest) quote token
        pnl: Float; // Realized P&L
        count: Nat; // Number of filled trades
        trades: [FilledTrade]; // history data
    };
    public type TraderData = {
        dexName: DexName;
        pair: PairCanister;
        quoteToken: {#token0; #token1};
        startTime: Time.Time;
        data: [TraderStats]; // The latest data is placed at position [0].
        endTime: ?Time.Time; // Set at the end of the competition
        total: ?(TraderStats, Float); 
    };
    public type TraderDataResponse = {
        pair: PairInfo;
        quoteToken: {#token0; #token1};
        startTime: Time.Time;
        data: [TraderStats];
        endTime: ?Time.Time;
        total: ?(TraderStats, Float); 
    };
    public type Config = { 
        SYS_TOKEN: Principal;
        BLACKHOLE: Principal;
        ORACLE: Principal;
        SCORE_G1: Nat; // 60
        SCORE_G2: Nat; // 50
        SCORE_G3: Nat; // 30
        SCORE_G4: Nat; // 20
    };
    public type ConfigRequest = { 
        SYS_TOKEN: ?Principal;
        BLACKHOLE: ?Principal;
        ORACLE: ?Principal;
        SCORE_G1: ?Nat; // 60
        SCORE_G2: ?Nat; // 50
        SCORE_G3: ?Nat; // 30
        SCORE_G4: ?Nat; // 20
    };
    public type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };
    public type Self = actor {
        getDexList : shared query () -> async [(DexName, Principal)];
        getTokens : shared query (_dexName: ?DexName) -> async [TokenInfo];
        getCurrencies : shared query () -> async [TokenInfo];
        getPairsByToken : shared query (_token: Principal, _dexName: ?DexName) -> async [(PairCanister, TradingPair)];
        getPairs : shared query (_dexName: ?DexName, _page: ?Nat, _size: ?Nat) -> async TrieList<PairCanister, TradingPair>;
        getPairs2 : shared query (_dexName: ?DexName, _lr: ?Principal, _page: ?Nat, _size: ?Nat) -> async TrieList<PairCanister, PairResponse>;
        route : shared query (_token0: Principal, _token1: Principal, _dexName: ?DexName) -> async [(PairCanister, TradingPair)];
        putByDex : shared (_token0: TokenInfo, _token1: TokenInfo, _canisterId: Principal) -> async ();
        removeByDex : shared (_pairCanister: Principal) -> async ();
        // pushCompetitionByPair : shared (_round: Nat, _name: Text, _start: Time.Time, _end: Time.Time) -> async ();
        pushCompetitionByDex : shared (_id: ?Nat, _name: Text, _content: Text, _start: Time.Time, _end: Time.Time, pairs: [(DexName, Principal, {#token0; #token1})]) -> async Nat;
        verifyListingReferrer : shared (_referrer: Principal, _name: Text, _verified: Bool) -> async ();
        setListingReferrerByNft : shared (_name: Text, _nftId: Text) -> async ();
        propose : shared (_pair: PairCanister) -> async ();
        listingReferrer : shared query (_referrer: Principal) -> async (_valid: Bool, verified: Bool);
        getPairListingReferrers : shared query (_pair: PairCanister) -> async (sponsored: Bool, listingReferrers: [(ListingReferrer, Time.Time, Text)]);
    };
};