unit UNetProtocol;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{ Copyright (c) 2016 by Albert Molina

  Distributed under the MIT software license, see the accompanying file LICENSE
  or visit http://www.opensource.org/licenses/mit-license.php.

  This unit is a part of Pascal Coin, a P2P crypto currency without need of
  historical operations.

  If you like it, consider a donation using BitCoin:
  16K3HCZRhFUtM8GdWRcfKeaa6KsuyxZaYk

  }

interface

Uses
{$IFnDEF FPC}
  Windows,
{$ELSE}
  {LCLIntf, LCLType, LMessages,}
{$ENDIF}
  UBlockChain, Classes, SysUtils, UAccounts, UThread,
  UCrypto, UTCPIP, SyncObjs, math, contnrs;

{$I config.inc}

Const
  CT_MagicRequest = $0001;
  CT_MagicResponse = $0002;
  CT_MagicAutoSend = $0003;

  CT_NetOp_Hello = $0001;              // Sends my last operationblock + servers. Receive last operationblock + servers + same operationblock number of sender
  CT_NetOp_Error = $0002;
  CT_NetOp_Message = $0003;
  CT_NetOp_GetBlocks = $0010;
  CT_NetOp_GetOperationsBlock = $0005; // Sends from and to. Receive a number of OperationsBlock to check
  CT_NetOp_NewBlock = $0011;
  CT_NetOp_AddOperations = $0020;


  CT_NetError_InvalidProtocolVersion = $0001;
  CT_NetError_IPBlackListed = $0002;
  CT_NetError_InvalidDataBufferInfo = $0010;
  CT_NetError_InternalServerError = $0011;
  CT_NetError_InvalidNewAccount = $0012;

Type
  {
  Net Protocol:

  3 different types: Request,Response or Auto-send
  Request:   <Magic Net Identification (4b)><request  (2b)><operation (2b)><0x0000 (2b)><request_id(4b)><protocol info(4b)><data_length(4b)><request_data (data_length bytes)>
  Response:  <Magic Net Identification (4b)><response (2b)><operation (2b)><error_code (2b)><request_id(4b)><protocol info(4b)><data_length(4b)><response_data (data_length bytes)>
  Auto-send: <Magic Net Identification (4b)><autosend (2b)><operation (2b)><0x0000 (2b)><0x00000000 (4b)><protocol info(4b)><data_length(4b)><data (data_length bytes)>

  Min size: 4b+2b+2b+2b+4b+4b+4b = 22 bytes
  Max size: (depends on last 4 bytes) = 22..(2^32)-1
  }

  TNetTransferType = (ntp_unknown, ntp_request, ntp_response, ntp_autosend);

  TNetProtocolVersion = Record
    protocol_version,
    protocol_available : Word;
  end;

  TNetHeaderData = Record
    header_type : TNetTransferType;
    protocol : TNetProtocolVersion;
    operation : Word;
    request_id : Cardinal;
    buffer_data_length : Cardinal;
    //
    is_error : Boolean;
    error_code : Integer;
    error_text : AnsiString;
  end;

  TNetConnection = Class;

  TNodeServerAddress = Record
    ip : AnsiString;
    port : Word;
    last_connection : Cardinal;
    last_connection_by_server : Cardinal;
    //
    netConnection : TNetConnection;
    its_myself : Boolean;
    last_attempt_to_connect : TDateTime;
    total_failed_attemps_to_connect : Integer;
    BlackListText : String;
  end;
  TNodeServerAddressArray = Array of TNodeServerAddress;
  PNodeServerAddress = ^TNodeServerAddress;

  TNetMessage_Hello = Record
     last_operation : TOperationBlock;
     servers_address : Array of TNodeServerAddress;
  end;

  TNetRequestRegistered = Record
    NetClient : TNetConnection;
    Operation : Word;
    RequestId : Cardinal;
    SendTime : QWord;
  end;
  PNetRequestRegistered = ^TNetRequestRegistered;

  TNetStatistics = Record
    ActiveConnections : Integer; // All connections wiht "connected" state
    ClientsConnections : Integer; // All clients connected to me like a server with "connected" state
    ServersConnections : Integer; // All servers where I'm connected
    ServersConnectionsWithResponse : Integer; // All servers where I'm connected and I've received data
    TotalConnections : Integer;
    TotalClientsConnections : Integer;
    TotalServersConnections : Integer;
    BytesReceived : Int64;
    BytesSend : Int64;
  end;

  TNetworkAdjustedTime = Class
  const
    MinSamples = 3; // Actually Bitcoin have 5 here. Consider to increase this value in the future.
    MaxSamples = 200;
  private
    FKnownClients : array [0..MaxSamples-1] of AnsiString;
    FTimeOffsets : array [0..MaxSamples-1] of Integer;
    FTimeOffsetsCount : Cardinal;
    FTimeOffset : Integer;
    FLock : TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Input(clientId : AnsiString; timeOffset : Integer);
    function GetAdjustedTime : Cardinal;
    property TimeOffset : Integer read FTimeOffset;
  end;

  TNetData = Class;

  TThreadGetNewBlockChainFromClient = Class(TThread)
  public
    constructor Create(netData : TNetData);
  protected
    procedure Execute; override;
  private
    FNetData : TNetData;
  end;

  TNetDataNotifyEventsThread = Class(TThread)
  private
    FNetData: TNetData;
    FNotifyOnReceivedHelloMessage : Boolean;
    FNotifyOnStatisticsChanged : Boolean;
    FNotifyOnNetConnectionsUpdated : Boolean;
    FNotifyOnNodeServersUpdated : Boolean;
    FNotifyOnBlackListUpdated : Boolean;
  protected
    procedure SynchronizedNotify;
    procedure Execute; override;
  public
    Constructor Create(ANetData : TNetData);
  End;

  TNetClientsDestroyThread = Class(TThread)
  private
    FNetData : TNetData;
    FTerminatedAllConnections : Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(NetData : TNetData);
    procedure WaitForTerminatedAllConnections;
  end;

  TThreadCheckConnections = Class(TThread)
  private
    FNetData : TNetData;
    FLastCheckTS : QWord;
  protected
    procedure Execute; override;
  public
    constructor Create(NetData : TNetData);
  end;

  TNetData = Class(TComponent)
  private
    FSocks5Address : string;
    FSocks5Port : Word;
    FNetworkAdjustedTime : TNetworkAdjustedTime;
    FNetDataNotifyEventsThread : TNetDataNotifyEventsThread;
    FNodePrivateKey : TECPrivateKey;
    FNetConnections : TPCThreadList;
    FNodeServers : TPCThreadList;
    FBlackList : TPCThreadList;
    FLastRequestId : Cardinal;
    FRegisteredRequests : TThreadList;
    FIsGettingNewBlockChainFromClient : Boolean;
    FOnNetConnectionsUpdated: TNotifyEvent;
    FOnNodeServersUpdated: TNotifyEvent;
    FOnBlackListUpdated: TNotifyEvent;
    FThreadCheckConnections : TThreadCheckConnections;
    FOnReceivedHelloMessage: TNotifyEvent;
    FNetStatistics: TNetStatistics;
    FOnStatisticsChanged: TNotifyEvent;
    FMaxRemoteOperationBlock : TOperationBlock;
    FFixedServers : TNodeServerAddressArray;
    FNetClientsDestroyThread : TNetClientsDestroyThread;
    FNetConnectionsActive: Boolean;

    Procedure IncStatistics(incActiveConnections,incClientsConnections,incServersConnections,incServersConnectionsWithResponse : Integer; incBytesReceived, incBytesSend : Int64);

    procedure SetNetConnectionsActive(const Value: Boolean);  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    Function IndexOfNetClient(ListToSearch : TList; ip : AnsiString; port : Word; indexStart : Integer = 0) : Integer;
    Procedure DeleteNetClient(List : TList; index : Integer);
    Procedure CleanBlackList;
  public
    Class function HeaderDataToText(const HeaderData : TNetHeaderData) : AnsiString;
    Class function ExtractHeaderInfo(buffer : TStream; var HeaderData : TNetHeaderData; DataBuffer : TStream; var IsValidHeaderButNeedMoreData : Boolean) : Boolean;
    Class Function OperationToText(operation : Word) : AnsiString;
    // Only 1 NetData
    Class Function NetData : TNetData;
    Class Function NetDataExists : Boolean;
    //
    Constructor Create(AOwner : TComponent; socks5Address : string; socks5Port : Word);
    Destructor Destroy; override;

    procedure SetSocks5(address: string; port: Word);
    Function Bank : TPCBank;
    Function NewRequestId : Cardinal;
    Procedure RegisterRequest(Sender: TNetConnection; operation : Word; request_id : Cardinal);
    Function UnRegisterRequest(Sender: TNetConnection; operation : Word; request_id : Cardinal) : Boolean;
    function PendingRequestAnyTime(Sender: TNetConnection) : QWord;
    function RequestAlive(requestId : Cardinal) : Boolean;
    Procedure AddServer(NodeServerAddress : TNodeServerAddress);
    Function IsBlackListed(const ip : AnsiString; port : Word) : Boolean;
    //
    Procedure DiscoverFixedServersOnly(const FixedServers : TNodeServerAddressArray);
    //
    Function ConnectionsCount(CountOnlyNetClients : Boolean) : Integer;
    Function Connection(index : Integer) : TNetConnection;
    Function ConnectionExistsAndActive(ObjectPointer : TObject) : Boolean;
    Function ConnectionExists(ObjectPointer : TObject) : Boolean;
    Function ConnectionsLock : TList;
    Procedure ConnectionsUnlock;
    Function ConnectionLock(Sender : TObject; ObjectPointer : TObject) : Boolean;
    Procedure ConnectionUnlock(ObjectPointer : TObject);
    Function FindConnectionByClientRandomValue(Sender : TNetConnection) : TNetConnection;
    Procedure DiscoverServers;
    Procedure DisconnectClients;
    Procedure GetNewBlockChainFromClient(Connection : TNetConnection; requestId : PCardinal = nil);
    Property BlackList : TPCThreadList read FBlackList;
    Property NodeServers : TPCThreadList read FNodeServers;
    Property NetConnections : TPCThreadList read FNetConnections;
    Property NetStatistics : TNetStatistics read FNetStatistics;
    Property NetworkAdjustedTime : TNetworkAdjustedTime read FNetworkAdjustedTime;
    function IsDiscoveringServers : Boolean;
    Property IsGettingNewBlockChainFromClient : Boolean read FIsGettingNewBlockChainFromClient;
    Property MaxRemoteOperationBlock : TOperationBlock read FMaxRemoteOperationBlock;
    Property NodePrivateKey : TECPrivateKey read FNodePrivateKey;
    Function GetValidNodeServers(OnlyWhereIConnected : Boolean): TNodeServerAddressArray;
    Property OnNetConnectionsUpdated : TNotifyEvent read FOnNetConnectionsUpdated write FOnNetConnectionsUpdated;
    Property OnNodeServersUpdated : TNotifyEvent read FOnNodeServersUpdated write FOnNodeServersUpdated;
    Property OnBlackListUpdated : TNotifyEvent read FOnBlackListUpdated write FOnBlackListUpdated;
    Property OnReceivedHelloMessage : TNotifyEvent read FOnReceivedHelloMessage write FOnReceivedHelloMessage;
    Property OnStatisticsChanged : TNotifyEvent read FOnStatisticsChanged write FOnStatisticsChanged;
    Procedure NotifyNetConnectionUpdated;
    Procedure NotifyNodeServersUpdated;
    Procedure NotifyBlackListUpdated;
    Procedure NotifyReceivedHelloMessage;
    Procedure NotifyStatisticsChanged;
    Property NetConnectionsActive : Boolean read FNetConnectionsActive write SetNetConnectionsActive;

  private
    FDiscoveringThreads : TThreadList;
    FDiscoveringThreadsCount : Cardinal;

    FBlockChainReceiver : TThreadGetNewBlockChainFromClient;
    FBlockChainUpdateRequests : Cardinal;
    FBlockChainUpdateEvent : PRTLEvent;

  private
    property DiscoveringThreadsCount : Cardinal read FDiscoveringThreadsCount;
    procedure ForceBlockchainUpdate;
  end;

  TNetConnection = Class(TComponent)
  private
    FNewBlocksUpdatesWaiting : Boolean;
    FNewOperationsList : TThreadList;

    FRefCount : Cardinal;
    FFreeClientOnDestroy : Boolean;
    FTcpIpClient : TNetTcpIpClient;
    FRemoteOperationBlock : TOperationBlock;
    FLastDataReceivedTS : QWord;
    FLastDataSendedTS : QWord;
    FClientBufferRead : TStream;
    FNetLock : TCriticalSection;
    FIsWaitingForResponse : Boolean;
    FLastKnownTimestampDiff : Int64;
    FIsMyselfServer : Boolean;
    FClientPublicKey : TAccountKey;
    FCreatedTime: TDateTime;
    FClientAppVersion: AnsiString;
    FDoFinalizeConnection : Boolean;
    FNetProtocolVersion: TNetProtocolVersion;
    FAlertedForNewProtocolAvailable : Boolean;
    FHasReceivedData : Boolean;
    FIsDownloadingBlocks : Boolean;
    function GetConnected: Boolean;
    procedure TcpClient_OnConnect(Sender: TObject);
    procedure TcpClient_OnDisconnect(Sender: TObject);
    Function DoSendAndWaitForResponse(operation: Word; RequestId: Integer; SendDataBuffer, ReceiveDataBuffer: TStream; MaxWaitTime : Cardinal; var HeaderData : TNetHeaderData) : Boolean;
    procedure DoProcessBuffer;
    Procedure DoProcess_Hello(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_Message(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_GetBlocks_Request(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_GetBlocks_Response(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_GetOperationsBlock_Request(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_NewBlock(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Procedure DoProcess_AddOperations(HeaderData : TNetHeaderData; DataBuffer: TStream);
    Function ReadTcpClientBuffer(MaxWaitMiliseconds : Cardinal; var HeaderData : TNetHeaderData; BufferData : TStream) : Boolean;
    Procedure DisconnectInvalidClient(ItsMyself : Boolean; Const why : AnsiString; blacklist : Boolean = true);
    procedure Initialize;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
    Procedure Send(NetTranferType : TNetTransferType; operation, errorcode : Word; request_id : Integer; DataBuffer : TStream);
    Procedure SendError(NetTranferType : TNetTransferType; operation, request_id : Integer; error_code : Integer; error_text : AnsiString);
  public
    constructor Create(AOwner : TComponent); override; overload;
    constructor Create(AOwner : TComponent; const client : TNetTcpIpClient); overload;
    destructor Destroy; override;

    Function ConnectTo(ServerIP: AnsiString; ServerPort:Word; stop : PBoolean = Nil) : Boolean;
    Property Connected : Boolean read GetConnected;
    Function Send_Hello(NetTranferType : TNetTransferType; request_id : Integer) : Boolean;
    Function Send_NewBlockFound : Boolean;
    Function Send_GetBlocks(StartAddress, quantity : Cardinal; var request_id : Cardinal) : Boolean;
    Function Send_AddOperations(Operations : TOperationsHashTree) : Boolean;
    Function Send_Message(Const TheMessage : AnsiString) : Boolean;
    Property Client : TNetTcpIpClient read FTcpIpClient;
    Function ClientRemoteAddr : AnsiString;
    //
    Property NetProtocolVersion : TNetProtocolVersion read FNetProtocolVersion;
    //
    Property IsMyselfServer : Boolean read FIsMyselfServer;
    Property CreatedTime : TDateTime read FCreatedTime;
    Property ClientAppVersion : AnsiString read FClientAppVersion write FClientAppVersion;
    Procedure FinalizeConnection;

    procedure QueueNewBlockBroadcast;
    procedure QueueNewOperationBroadcast(MakeACopyOfOperationsHashTree : TOperationsHashTree);
    procedure BroadcastNewBlocksAndOperations;

    function RefAdd : Boolean;
    procedure RefDec;
  End;

  TNetClient = Class;
  TNetClientThread = Class(TThread)
  private
    FNetClient : TNetClient;
  protected
    procedure Execute; override;
  public
    Constructor Create(NetClient : TNetClient; AOnTerminateThread : TNotifyEvent);
  End;

  TNetClient = Class(TNetConnection)
  private
    FNetClientThread : TNetClientThread;
    Procedure OnNetClientThreadTerminated(Sender : TObject);
  public
    Constructor Create(AOwner : TComponent); override;
    Destructor Destroy; override;
  End;

  TNetServerClient = Class(TNetConnection);

  TNetServer = Class(TNetTcpIpServer)
  private
  protected
    Procedure OnNewIncommingConnection(Sender : TObject; Client : TNetTcpIpClient); override;
    procedure SetActive(const Value: Boolean); override;
  public
    Constructor Create; override;
  End;

  TThreadDiscoverConnection = Class(TThread)
  private
    FNodeServerAddress : TNodeServerAddress;
    FNetData : TNetData;
  protected
    procedure Execute; override;
  public
    Constructor Create(NodeServerAddress: TNodeServerAddress; netData : TNetData);
  End;


Const
  CT_TNodeServerAddress_NUL : TNodeServerAddress = (ip:'';port:0;last_connection:0;last_connection_by_server:0; netConnection:nil;its_myself:false;last_attempt_to_connect:0;total_failed_attemps_to_connect:0;BlackListText:'');
  CT_TNetStatistics_NUL : TNetStatistics = (ActiveConnections:0;ClientsConnections:0;ServersConnections:0;ServersConnectionsWithResponse:0;TotalConnections:0;TotalClientsConnections:0;TotalServersConnections:0;BytesReceived:0;BytesSend:0);

implementation

uses
  UConst, ULog, UNode, UTime, UECIES;

Const
  CT_NetTransferType : Array[TNetTransferType] of AnsiString = ('Unknown','Request','Response','Autosend');
  CT_NetHeaderData : TNetHeaderData = (header_type:ntp_unknown;protocol:(protocol_version:0;protocol_available:0);operation:0;request_id:0;buffer_data_length:0;is_error:false;error_code:0;error_text:'');

{ TNetData }

Var _NetData : TNetData = nil;

function SortNodeServerAddress(Item1, Item2: Pointer): Integer;
Var P1,P2 : PNodeServerAddress;
Begin
  P1 := Item1;
  P2 := Item2;
  Result := AnsiCompareText(P1.ip,P2.ip);
  if Result=0 then Result := P1.port - P2.port;
End;

Constructor TNetworkAdjustedTime.Create;
begin
  FLock := TCriticalSection.Create;
end;

destructor TNetworkAdjustedTime.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end;

function Comp(p1, p2: pointer): integer;
begin
 result := -1;
 if Integer(p1) = Integer(p2) then
   result := 0
 else if Integer(p1) > Integer(p2) then
   result := 1;
end;

procedure TNetworkAdjustedTime.Input(clientId : AnsiString; timeOffset : Integer);
var
  i : Byte;
  sorted : TList;
begin
  FLock.Acquire;
  try
    TLog.NewLog(ltdebug, Classname, Format('Input: %s %d', [clientId, timeOffset]));

    if FTimeOffsetsCount > MaxSamples-1 then begin
      Exit;
    end;

    for i := 0 to FTimeOffsetsCount do begin
      if FKnownClients[i] = clientId then begin
        Exit;
      end;
    end;

    FKnownClients[FTimeOffsetsCount] := clientId;
    FTimeOffsets[FTimeOffsetsCount] := timeOffset;
    Inc(FTimeOffsetsCount);

    if FTimeOffsetsCount < MinSamples then begin
       Exit;
    end;

    sorted := TList.Create;
    try
      for i := 0 to FTimeOffsetsCount do begin
        sorted.Add(Pointer(FTimeOffsets[i]));
      end;

      sorted.Sort(Comp);

      TLog.NewLog(ltdebug, Classname, Format('FTimeOffsetsCount: %d', [FTimeOffsetsCount]));
      if FTimeOffsetsCount And 1 = 1 then begin
        FTimeOffset := Integer(sorted.Items[FTimeOffsetsCount DIV 2]);
      end else begin
        FTimeOffset := (Integer(sorted.Items[FTimeOffsetsCount DIV 2 - 1]) + Integer(sorted.Items[FTimeOffsetsCount DIV 2])) DIV 2;
      end;
      TLog.NewLog(ltinfo, Classname, Format('Network time offset: %d', [FTimeOffset]));
    finally
      sorted.Free;
    end;
  finally
    FLock.Release;
  end;
end;

function TNetworkAdjustedTime.GetAdjustedTime : Cardinal;
begin
 Result := UnivDateTimeToUnix(DateTime2UnivDateTime(now)) + FTimeOffset;
end;

procedure TNetData.AddServer(NodeServerAddress: TNodeServerAddress);
Var P : PNodeServerAddress;
  i : Integer;
  l : TList;
begin
  l := FNodeServers.LockList;
  try
    i := IndexOfNetClient(l,NodeServerAddress.ip,NodeServerAddress.port);
    if i>=0 then begin
      P := PNodeServerAddress(l[i]);
      if NodeServerAddress.last_connection>P^.last_connection then P^.last_connection := NodeServerAddress.last_connection;
      if NodeServerAddress.last_connection_by_server>P^.last_connection_by_server then P^.last_connection_by_server := NodeServerAddress.last_connection_by_server;
      if NodeServerAddress.last_attempt_to_connect>P^.last_attempt_to_connect then P^.last_attempt_to_connect := NodeServerAddress.last_attempt_to_connect;
      exit;
    end;
    New(P);
    P^ := NodeServerAddress;
    l.Add(P);
    l.Sort(SortNodeServerAddress);
    TLog.NewLog(ltdebug,Classname,'Adding new server: '+NodeServerAddress.ip+':'+Inttostr(NodeServerAddress.port));
  finally
    FNodeServers.UnlockList;
  end;
  NotifyNodeServersUpdated;
end;

procedure TNetData.SetSocks5(address : string; port : Word);
begin
  if (address <> FSocks5Address) or (port <> FSocks5Port) then
  begin
    FSocks5Address := address;
    FSocks5Port := port;
    DisconnectClients;
  end;
end;

function TNetData.Bank: TPCBank;
begin
  Result := TNode.Node.Bank;
end;

procedure TNetData.CleanBlackList;
Var P,Pns : PNodeServerAddress;
  i,n,j : Integer;
  l,lns : TList;
begin
  // This procedure cleans old blacklisted IPs
  n := 0;
  l := FBlackList.LockList;
  Try
    for i := l.Count - 1 downto 0 do begin
      P := l[i];
      // Is an old blacklisted IP? (More than 1 hour)
      If ((P^.last_connection+(60*60)) < (UnivDateTimeToUnix(DateTime2UnivDateTime(now)))) then begin
        // Clean from FNodeServers
        lns := FNodeServers.LockList;
        Try
          j := IndexOfNetClient(lns,P^.ip,P^.port);
          if (j>=0) then begin
            Pns := lns[j];
            Pns^.its_myself := false;
            Pns^.BlackListText := '';
          end;
        Finally
          FNodeServers.UnlockList;
        End;
        l.Delete(i);
        Dispose(P);
        inc(n);
      end;
    end;
  Finally
    FBlackList.UnlockList;
  End;
  if (n>0) then NotifyBlackListUpdated;
end;

function TNetData.Connection(index: Integer): TNetConnection;
Var l : TList;
begin
  l := ConnectionsLock;
  try
    Result := TNetConnection( l[index] );
  finally
    ConnectionsUnlock;
  end;
end;

function TNetData.ConnectionExists(ObjectPointer: TObject): Boolean;
var i : Integer;
  l : TList;
begin
  Result := false;
  l := ConnectionsLock;
  try
    for i := 0 to l.Count - 1 do begin
      if TObject(l[i])=ObjectPointer then begin
        Result := true;
        exit;
      end;
    end;
  finally
    ConnectionsUnlock;
  end;
end;

function TNetData.ConnectionExistsAndActive(ObjectPointer: TObject): Boolean;
var i : Integer;
  l : TList;
begin
  Result := false;
  l := ConnectionsLock;
  try
    for i := 0 to l.Count - 1 do begin
      if TObject(l[i])=ObjectPointer then begin
        Result := (TNetConnection(ObjectPointer).Connected);
        exit;
      end;
    end;
  finally
    ConnectionsUnlock;
  end;
end;

function TNetData.ConnectionLock(Sender : TObject; ObjectPointer: TObject): Boolean;
var i : Integer;
  l : TList;
begin
  Result := false;
  l := ConnectionsLock;
  try
    for i := 0 to l.Count - 1 do begin
      if TObject(l[i])=ObjectPointer then begin
        Result := TPCThread.TryProtectEnterCriticalSection(Sender,500,TNetConnection(l[i]).FNetLock);
        exit;
      end;
    end;
  finally
    ConnectionsUnlock;
  end;
end;

function TNetData.ConnectionsCount(CountOnlyNetClients : Boolean): Integer;
var i : Integer;
  l : TList;
begin
  l := ConnectionsLock;
  try
    if CountOnlyNetClients then begin
      Result := 0;
      for i := 0 to l.Count - 1 do begin
        if TObject(l[i]) is TNetClient then inc(Result);
      end;
    end else Result := l.Count;
  finally
    ConnectionsUnlock;
  end;
end;

function TNetData.ConnectionsLock: TList;
begin
  Result := FNetConnections.LockList;
end;

procedure TNetData.ConnectionsUnlock;
begin
  FNetConnections.UnlockList;
end;

procedure TNetData.ConnectionUnlock(ObjectPointer: TObject);
var i : Integer;
  l : TList;
begin
  l := ConnectionsLock;
  try
    for i := 0 to l.Count - 1 do begin
      if TObject(l[i])=ObjectPointer then begin
        TNetConnection(l[i]).FNetLock.Release;
        exit;
      end;
    end;
  finally
    ConnectionsUnlock;
  end;
end;

constructor TNetData.Create(AOwner : TComponent; socks5Address : string; socks5Port : Word);
begin
  inherited Create(AOwner);

  TLog.NewLog(ltInfo,ClassName,'TNetData.Create');

  FNetConnectionsActive := true;
  SetLength(FFixedServers,0);
  FMaxRemoteOperationBlock := CT_OperationBlock_NUL;
  FNetStatistics := CT_TNetStatistics_NUL;
  FOnStatisticsChanged := Nil;
  FOnNetConnectionsUpdated := Nil;
  FOnNodeServersUpdated := Nil;
  FOnBlackListUpdated := Nil;
  FOnReceivedHelloMessage := Nil;
  FNodeServers := TPCThreadList.Create;
  FRegisteredRequests := TThreadList.Create;
  FLastRequestId := 0;
  FNetConnections := TPCThreadList.Create;
  SetSocks5(socks5Address, socks5Port);
  FNetworkAdjustedTime := TNetworkAdjustedTime.Create;
  FBlackList := TPCThreadList.Create;
  FIsGettingNewBlockChainFromClient := false;
  FNodePrivateKey := TECPrivateKey.Create;
  FNodePrivateKey.GenerateRandomPrivateKey(CT_Default_EC_OpenSSL_NID);
  FThreadCheckConnections := TThreadCheckConnections.Create(Self);
  FNetDataNotifyEventsThread := TNetDataNotifyEventsThread.Create(Self);
  FNetClientsDestroyThread := TNetClientsDestroyThread.Create(Self);

  FDiscoveringThreads := TThreadList.Create;
  FBlockChainUpdateEvent := RTLEventCreate;
  FBlockChainReceiver := TThreadGetNewBlockChainFromClient.Create(Self);

  If Not Assigned(_NetData) then _NetData := Self;
end;

procedure TNetData.DeleteNetClient(List: TList; index: Integer);
Var P : PNodeServerAddress;
begin
  P := List.Items[index];
  List.Delete(index);
  Dispose(P);
end;

destructor TNetData.Destroy;
Var l : TList;
  i : Integer;
  list : TList;
  tdc : TThreadDiscoverConnection;
begin
  TLog.NewLog(ltInfo,ClassName,'TNetData.Destroy START');
  FOnStatisticsChanged := Nil;
  FOnNetConnectionsUpdated := Nil;
  FOnNodeServersUpdated := Nil;
  FOnBlackListUpdated := Nil;
  FOnReceivedHelloMessage := Nil;

  // First destroy ThreadCheckConnections to prevent a call to "DiscoverServers"
  FThreadCheckConnections.Terminate;
  FThreadCheckConnections.WaitFor;
  FreeAndNil(FThreadCheckConnections);

  // Now finish all DiscoverConnection threads
  list := FDiscoveringThreads.LockList;
  try
    for tdc in list do begin
      tdc.Terminate;
    end;
  finally
    FDiscoveringThreads.UnlockList;
  end;
  while IsDiscoveringServers do begin
    Sleep(100);
  end;
  FreeAndNil(FDiscoveringThreads);

  FBlockChainReceiver.Terminate;
  ForceBlockchainUpdate;
  FBlockChainReceiver.WaitFor;
  FreeAndNil(FBlockChainReceiver);
  RTLeventdestroy(FBlockChainUpdateEvent);

  // Closing connections
  l := ConnectionsLock;
  Try
    for i := 0 to l.Count - 1 do begin
      TNetConnection(l[i]).FTcpIpClient.Disconnect;
      TNetConnection(l[i]).FinalizeConnection;
    end;
  Finally
    ConnectionsUnlock;
  End;

  FNetClientsDestroyThread.WaitForTerminatedAllConnections;
  FNetClientsDestroyThread.Terminate;
  FNetClientsDestroyThread.WaitFor;
  FreeAndNil(FNetClientsDestroyThread);

  CleanBlackList;
  l := FNodeServers.LockList;
  try
    while (l.Count>0) do DeleteNetClient(l,l.Count-1);
  finally
    FNodeServers.UnlockList;
    FreeAndNil(FNodeServers);
  end;
  FreeAndNil(FNetworkAdjustedTime);

  l := FBlackList.LockList;
  try
    while (l.Count>0) do DeleteNetClient(l,l.Count-1);
  finally
    FBlackList.UnlockList;
    FreeAndNil(FBlackList);
  end;

  FreeAndNil(FNetConnections);
  FreeAndNil(FNodePrivateKey);
  FNetDataNotifyEventsThread.Terminate;
  FNetDataNotifyEventsThread.WaitFor;
  FreeAndNil(FNetDataNotifyEventsThread);
  SetLength(FFixedServers,0);
  FreeAndNil(FRegisteredRequests);

  inherited;
  if (_NetData=Self) then _NetData := Nil;
  TLog.NewLog(ltInfo,ClassName,'TNetData.Destroy END');
end;

procedure TNetData.DisconnectClients;
var i : Integer;
  l : TList;
begin
  l := ConnectionsLock;
  Try
    for i := l.Count - 1 downto 0 do begin
      if TObject(l[i]) is TNetClient then begin
        TNetClient(l[i]).FTcpIpClient.Disconnect;
        TNetClient(l[i]).FinalizeConnection;
      end;
    end;
  Finally
    ConnectionsUnlock;
  End;
end;

procedure TNetData.DiscoverFixedServersOnly(const FixedServers: TNodeServerAddressArray);
var
  i : Integer;
begin
  FNodeServers.LockList;
  try
    SetLength(FFixedServers,length(FixedServers));
    for i := low(FixedServers) to high(FixedServers) do begin
      FFixedServers[i] := FixedServers[i];
    end;
    for i := low(FixedServers) to high(FixedServers) do begin
      AddServer(FixedServers[i]);
    end;
  finally
    FNodeServers.UnlockList;
  end;
end;

procedure TNetData.DiscoverServers;
  Procedure sw(l : TList);
  Var i,j,x,y : Integer;
  begin
    if l.Count<=1 then exit;
    j := Random(l.Count)*3;
    for i := 0 to j do begin
      x := Random(l.Count);
      y := Random(l.Count);
      if x<>y then l.Exchange(x,y);
    end;
  end;
Var P : PNodeServerAddress;
  i,j,k : Integer;
  l,lns : TList;
  tdc : TThreadDiscoverConnection;
  canAdd : Boolean;
begin
  if Not FNetConnectionsActive then exit;

  if IsDiscoveringServers then
  begin
    TLog.NewLog(ltInfo,ClassName,'Allready discovering servers...');
    exit;
  end;

  CleanBlackList;
  If NetStatistics.ClientsConnections>0 then begin
    j := CT_MinServersConnected - NetStatistics.ServersConnectionsWithResponse;
  end else begin
    j := CT_MaxServersConnected - NetStatistics.ServersConnectionsWithResponse;
  end;
  if j<=0 then exit;
  // can discover up to j servers
  l := TList.Create;
  try
    lns := FNodeServers.LockList;
    try
      for i:=0 to lns.Count-1 do begin
        P := lns[i];
        If (Not Assigned(P.netConnection)) AND (Not IsBlackListed(P^.ip,P^.port)) AND (Not P^.its_myself) And
          ((P^.last_attempt_to_connect=0) Or ((P^.last_attempt_to_connect+EncodeTime(0,3,0,0)<now))) And
          ((P^.total_failed_attemps_to_connect<3) Or (P^.last_attempt_to_connect+EncodeTime(0,10,0,0)<now)) then begin

          if Length(FFixedServers)>0 then begin
            canAdd := false;
            for k := low(FFixedServers) to high(FFixedServers) do begin
              if (FFixedServers[k].ip=P^.ip) And
                 ((FFixedServers[k].port=P.port)) then begin
                 canAdd := true;
                 break;
              end;
            end;
          end else canAdd := true;
          if canAdd then l.Add(P);
        end;
      end;
      if l.Count<=0 then exit;
      sw(l);
      if j>=l.Count then j:=l.Count-1;
      TLog.NewLog(ltDebug,Classname,'Start discovering up to '+inttostr(j+1)+' servers... (max:'+inttostr(l.count)+')');
      //
      for i := 0 to j do begin
        P := PNodeServerAddress(l[i]);
        InterLockedIncrement(FDiscoveringThreadsCount);
        tdc := TThreadDiscoverConnection.Create(P^, Self);
        FDiscoveringThreads.Add(tdc);
      end;
    Finally
      FNodeServers.UnlockList;
    end;
  finally
    l.Free;
  end;
end;

function TNetData.IsDiscoveringServers : Boolean;
begin
  Result := DiscoveringThreadsCount > 0;
end;

procedure TNetData.ForceBlockchainUpdate;
begin
  InterLockedIncrement(FBlockChainUpdateRequests);
  RTLeventSetEvent(FBlockChainUpdateEvent);
end;

class function TNetData.ExtractHeaderInfo(buffer : TStream; var HeaderData : TNetHeaderData; DataBuffer : TStream; var IsValidHeaderButNeedMoreData : Boolean) : Boolean;
Var lastp : Integer;
  c : Cardinal;
  w : Word;
begin
  HeaderData := CT_NetHeaderData;
  Result := false;
  IsValidHeaderButNeedMoreData := false;
  lastp := buffer.Position;
  Try
    if buffer.Size-buffer.Position < 22 then exit;
    buffer.Read(c,4);
    if (c<>CT_MagicNetIdentification) then exit;
    buffer.Read(w,2);
    case w of
      CT_MagicRequest : HeaderData.header_type := ntp_request;
      CT_MagicResponse : HeaderData.header_type := ntp_response;
      CT_MagicAutoSend : HeaderData.header_type := ntp_autosend;
    else
      HeaderData.header_type := ntp_unknown;
      exit;
    end;
    buffer.Read(HeaderData.operation,2);
    buffer.Read(HeaderData.error_code,2);
    buffer.Read(HeaderData.request_id,4);
    buffer.Read(HeaderData.protocol.protocol_version,2);
    buffer.Read(HeaderData.protocol.protocol_available,2);
    buffer.Read(c,4);
    DataBuffer.Size := 0;
    if buffer.Size - buffer.Position < c then begin
      IsValidHeaderButNeedMoreData := true;
      exit;
    end;
    DataBuffer.CopyFrom(buffer,c);
    DataBuffer.Position := 0;
    HeaderData.buffer_data_length := c;
    //
    if HeaderData.header_type=ntp_response then begin
      HeaderData.is_error := HeaderData.error_code<>0;
      if HeaderData.is_error then begin
        TStreamOp.ReadAnsiString(DataBuffer,HeaderData.error_text);
      end;
    end else begin
      HeaderData.is_error := HeaderData.error_code<>0;
      if HeaderData.is_error then begin
        TStreamOp.ReadAnsiString(DataBuffer,HeaderData.error_text);
      end;
    end;
    if (HeaderData.is_error) then begin
      TLog.NewLog(lterror,Classname,'Response with error ('+IntToHex(HeaderData.error_code,4)+'): '+HeaderData.error_text+' ...on '+
        'operation: '+OperationToText(HeaderData.operation)+' id: '+Inttostr(HeaderData.request_id));
    end;
    Result := true;
  Finally
    if Not Result then buffer.Position := lastp;
  End;
end;

function TNetData.FindConnectionByClientRandomValue(Sender: TNetConnection): TNetConnection;
Var l : TList;
  i : Integer;
begin
  l := ConnectionsLock;
  try
    for i := 0 to L.Count - 1 do begin
      Result := TNetConnection( l[i] );
      If TAccountComp.Equal(Result.FClientPublicKey,Sender.FClientPublicKey) And (Sender<>Result) then exit;
    end;
  finally
    ConnectionsUnlock;
  end;
  Result := Nil;
end;

procedure TNetData.GetNewBlockChainFromClient(Connection: TNetConnection; requestId : PCardinal = nil);
Const CT_LogSender = 'GetNewBlockChainFromClient';

  function Do_GetOperationsBlock(AssignToBank : TPCBank; block_start,block_end, MaxWaitMilliseconds : Cardinal; OnlyOperationBlock : Boolean; BlocksList : TList) : Boolean;
  Var SendData,ReceiveData : TMemoryStream;
    headerdata : TNetHeaderData;
    op : TPCOperationsComp;
    request_id,opcount,i : Cardinal;
    errors : AnsiString;
    noperation : Integer;
  begin
    Result := false;
    BlocksList.Count := 0;
    if (Connection.FRemoteOperationBlock.block<block_end) then block_end := Connection.FRemoteOperationBlock.block;
    // First receive operations from
    SendData := TMemoryStream.Create;
    ReceiveData := TMemoryStream.Create;
    try
      if OnlyOperationBlock then begin
        noperation := CT_NetOp_GetOperationsBlock;
      end else begin
        noperation := CT_NetOp_GetBlocks;
      end;
      TLog.NewLog(ltdebug,CT_LogSender,Format('Sending %s from block %d to %d (Total: %d)',
        [TNetData.OperationToText(noperation),block_start,block_end,block_end-block_start+1]));
      SendData.Write(block_start,4);
      SendData.Write(block_end,4);
      request_id := TNetData.NetData.NewRequestId;
      if Connection.DoSendAndWaitForResponse(noperation,request_id,SendData,ReceiveData,MaxWaitMilliseconds,headerdata) then begin
        if HeaderData.is_error then exit;
        if ReceiveData.Read(opcount,4)<4 then exit; // Error in data
        i := 0;
        while (i<opcount) do begin
          // decode data
          op := TPCOperationsComp.Create(AssignToBank);
          If op.LoadBlockFromStream(ReceiveData,errors) then begin
            BlocksList.Add(op);
          end else begin
            TLog.NewLog(lterror,CT_LogSender,Format('Error reading OperationBlock from received stream %d/%d: %s',[i+1,opcount,errors]));
            op.free;
            break;
          end;
          inc(i);
        end;
        Result := true;
      end else begin
        TLog.NewLog(lterror,CT_LogSender,Format('No received response after waiting %d request id %d operation %s',[MaxWaitMilliseconds,request_id,TNetData.OperationToText(noperation)]));
      end;
    finally
      SendData.Free;
      ReceiveData.free;
    end;
  end;

  function Do_GetOperationBlock(block, MaxWaitMilliseconds : Cardinal; var OperationBlock : TOperationBlock) : Boolean;
  Var BlocksList : TList;
    i : Integer;
  begin
    OperationBlock := CT_OperationBlock_NUL;
    BlocksList := TList.Create;
    try
      Result := Do_GetOperationsBlock(TNode.Node.Bank,block,block,MaxWaitMilliseconds,false,BlocksList);
      if (Result) And (BlocksList.Count=1) then begin
        OperationBlock := TPCOperationsComp(BlocksList[0]).OperationBlock;
      end;
    finally
      for i := 0 to BlocksList.Count - 1 do TPCOperationsComp(BlocksList[i]).Free;
      BlocksList.Free;
    end;
  end;

  Function FindLastSameBlockByOperationsBlock(min,max : Cardinal; var OperationBlock : TOperationBlock) : Boolean;
  var i : Integer;
    ant_nblock : Int64;
    myops : TPCOperationsComp;
    auxBlock : TOperationBlock;
    distinctmax,distinctmin : Cardinal;
    BlocksList : TList;
  Begin
    Result := false;
    OperationBlock := CT_OperationBlock_NUL;
    repeat
      BlocksList := TList.Create;
      try
        If Not Do_GetOperationsBlock(Nil,min,max,5000,true,BlocksList) then exit;
        distinctmin := min;
        distinctmax := max;
        myops := TPCOperationsComp.Create(TNode.Node.Bank);
        try
          ant_nblock := -1;
          for i := 0 to BlocksList.Count - 1 do begin
            auxBlock := TPCOperationsComp(BlocksList[i]).OperationBlock;
            // Protection of invalid clients:
            if (auxBlock.block<min) Or (auxBlock.block>max) Or (auxBlock.block=ant_nblock) then begin
              Connection.DisconnectInvalidClient(false,'Invalid response... '+inttostr(min)+'<'+inttostr(auxBlock.block)+'<'+inttostr(max)+' ant:'+inttostr(ant_nblock));
              exit;
            end;
            ant_nblock := auxBlock.block;
            //
            If Not TNode.Node.Bank.LoadOperations(myops,auxBlock.block) then exit;

            if ((myops.OperationBlock.proof_of_work = auxBlock.proof_of_work) And (myops.OperationBlock.nonce = auxBlock.nonce)) then begin
              distinctmin := auxBlock.block;
              OperationBlock := auxBlock;
            end else begin
              if auxBlock.block<=distinctmax then
                distinctmax := auxBlock.block-1;
            end;
          end;
        finally
          myops.Free;
        end;
        min := math.min(distinctmin, distinctmax);
        max := distinctmax;
      finally
        for i := 0 to BlocksList.Count - 1 do begin
          TPCOperationsComp(BlocksList[i]).Free;
        end;
        BlocksList.Free;
      end;
    until (min = max);
    Result := (OperationBlock.proof_of_work <> CT_OperationBlock_NUL.proof_of_work);
  End;

  Function GetNewBank(start_block : Int64) : Boolean;
  var
    BlocksList : TList;
    i : Integer;
    OpComp,OpExecute : TPCOperationsComp;
    newBlock : TBlockAccount;
    errors : AnsiString;
    start : Cardinal;
    finished : Boolean;
    Bank : TPCBank;
    ms : TMemoryStream;
  Begin
    TLog.NewLog(ltdebug,CT_LogSender,Format('GetNewBank(new_start_block:%d)',[start_block]));
    Bank := TPCBank.Create(Nil);
    try
      Bank.StorageClass := TNode.Node.Bank.StorageClass;
      Bank.Storage.Orphan := TNode.Node.Bank.Storage.Orphan;
      Bank.Storage.ReadOnly := true;
      Bank.Storage.CopyConfiguration(TNode.Node.Bank.Storage);
      if start_block>=0 then begin
        // Restore a part
        Bank.DiskRestoreFromOperations(start_block-1);
        start := Math.min(Bank.BlocksCount, start_block);
      end else begin
        start := 0;
        start_block := 0;
      end;
      Bank.Storage.Orphan := FormatDateTime('yyyymmddhhnnss',DateTime2UnivDateTime(now));
      Bank.Storage.ReadOnly := false;
      // Receive new blocks:
      finished := false;
      repeat
        BlocksList := TList.Create;
        try
          finished := NOT Do_GetOperationsBlock(Bank,start,start + 50,5000,false,BlocksList);
          i := 0;
          while (i<BlocksList.Count) And (Not finished) do begin
            OpComp := TPCOperationsComp(BlocksList[i]);
            ms := TMemoryStream.Create;
            OpExecute := TPCOperationsComp.Create(Bank);
            try
              OpComp.SaveBlockToStream(false,ms);
              ms.Position := 0;
              OpExecute.LoadBlockFromStream(ms,errors);
              if Bank.AddNewBlockChainBlock(OpExecute,newBlock,errors, TNetData.NetData.NetworkAdjustedTime.TimeOffset) then begin
                inc(i);
              end else begin
                TLog.NewLog(lterror,CT_LogSender,'Error creating new bank with client Operations. Block:'+TPCOperationsComp.OperationBlockToText(OpExecute.OperationBlock)+' Error:'+errors);
                // Add to blacklist !
                Connection.DisconnectInvalidClient(false,'Invalid BlockChain on Block '+TPCOperationsComp.OperationBlockToText(OpExecute.OperationBlock)+' with errors:'+errors);
                finished := true;
                break;
              end;
            finally
              ms.Free;
              OpExecute.Free;
            end;
          end;
        finally
          for i := 0 to BlocksList.Count - 1 do TPCOperationsComp(BlocksList[i]).Free;
          BlocksList.Free;
        end;
        start := Bank.BlocksCount;
      until (Bank.BlocksCount=Connection.FRemoteOperationBlock.block+1) Or (finished);
      if Bank.BlocksCount>TNode.Node.Bank.BlocksCount then begin
        TNode.Node.DisableNewBlocks;
        Try
          // I'm an orphan blockchain...
          TLog.NewLog(ltinfo,CT_LogSender,'New valid blockchain found. My block count='+inttostr(TNode.Node.Bank.BlocksCount)+
            ' found='+inttostr(Bank.BlocksCount)+' starting at block '+inttostr(start_block));
          TNode.Node.Bank.Storage.MoveBlockChainBlocks(start_block,Inttostr(start_block)+'_'+FormatDateTime('yyyymmddhhnnss',DateTime2UnivDateTime(now)),Nil);
          Bank.Storage.MoveBlockChainBlocks(start_block,TNode.Node.Bank.Storage.Orphan,TNode.Node.Bank.Storage);
          TNode.Node.Bank.DiskRestoreFromOperations(CT_MaxBlock);
        Finally
          TNode.Node.EnableNewBlocks;
        End;
      end;
    finally
      Bank.Free;
    end;
  End;

var
  rid : Cardinal;
  my_op, client_op : TOperationBlock;
begin
  If FIsGettingNewBlockChainFromClient then begin
    TLog.NewLog(ltdebug,CT_LogSender,'Is getting new blockchain from client...');
    exit;
  end else TLog.NewLog(ltdebug,CT_LogSender,'Starting receiving');
  Try
    FIsGettingNewBlockChainFromClient := true;
    FMaxRemoteOperationBlock := Connection.FRemoteOperationBlock;
    if TNode.Node.Bank.BlocksCount=0 then begin
      TLog.NewLog(ltdebug,CT_LogSender,'I have no blocks');
      Connection.Send_GetBlocks(0,10,rid);
      if Assigned(requestId) then begin
        requestId^ := rid;
      end;
      exit;
    end;
    TLog.NewLog(ltdebug,CT_LogSender,'Starting GetNewBlockChainFromClient at client:'+Connection.ClientRemoteAddr+
      ' with OperationBlock:'+TPCOperationsComp.OperationBlockToText(Connection.FRemoteOperationBlock)+' (My block: '+TPCOperationsComp.OperationBlockToText(TNode.Node.Bank.LastOperationBlock)+')');
    // NOTE: FRemoteOperationBlock.block >= TNode.Node.Bank.BlocksCount
    // First capture same block than me (TNode.Node.Bank.BlocksCount-1) to check if i'm an orphan block...
    my_op := TNode.Node.Bank.LastOperationBlock;
    If Not Do_GetOperationBlock(my_op.block,5000,client_op) then begin
      TLog.NewLog(lterror,CT_LogSender,'Cannot receive information about my block ('+inttostr(my_op.block)+')...');
      // Disabled at Build 1.0.6 >  Connection.DisconnectInvalidClient(false,'Cannot receive information about my block ('+inttostr(my_op.block)+')... Invalid client. Disconnecting');
      exit;
    end;

    if (NOT TPCOperationsComp.EqualsOperationBlock(my_op,client_op)) then begin
      TLog.NewLog(ltinfo,CT_LogSender,'My blockchain is incorrect... received: '+TPCOperationsComp.OperationBlockToText(client_op)+' My: '+TPCOperationsComp.OperationBlockToText(my_op));
      if Not FindLastSameBlockByOperationsBlock(0,client_op.block,client_op) then begin
        TLog.NewLog(ltinfo,CT_LogSender,'No found base block to start process... Receiving ALL');
        GetNewBank(-1);
      end else begin
        TLog.NewLog(ltinfo,CT_LogSender,'Found base new block: '+TPCOperationsComp.OperationBlockToText(client_op));
        // Move operations to orphan folder... (temporal... waiting for a confirmation)
        GetNewBank(client_op.block);
      end;
    end else begin
      TLog.NewLog(ltinfo,CT_LogSender,'My blockchain is ok! Need to download new blocks starting at '+inttostr(my_op.block+1));
      // High to new value:
      Connection.Send_GetBlocks(my_op.block+1,100,rid);
      if Assigned(requestId) then begin
        requestId^ := rid;
      end;
    end;
  Finally
    TLog.NewLog(ltdebug,CT_LogSender,'Finalizing');
    FIsGettingNewBlockChainFromClient := false;
  end;
end;

function TNetData.GetValidNodeServers(OnlyWhereIConnected : Boolean): TNodeServerAddressArray;
var i : Integer;
  nsa : TNodeServerAddress;
  currunixtimestamp : Cardinal;
  l : TList;
begin
  SetLength(Result,0);
  currunixtimestamp := UnivDateTimeToUnix(DateTime2UnivDateTime(now));
  // Save other node servers
  l := FNodeServers.LockList;
  try
    for i := 0 to l.Count - 1 do begin
      nsa := PNodeServerAddress( l[i] )^;
      if (Not IsBlackListed(nsa.ip,0))
        And
        ( // I've connected 24h before
         ((nsa.last_connection>0) And ((Assigned(nsa.netConnection)) Or ((nsa.last_connection + (60*60*24)) > (currunixtimestamp))))
         Or // Others have connected 24h before
         ((nsa.last_connection_by_server>0) And ((nsa.last_connection_by_server + (60*60*24)) > (currunixtimestamp)))
         Or // Peer cache
         ((nsa.last_connection=0) And (nsa.last_connection_by_server=0))
        )
        And
        ( // Never tried to connect or successfully connected
          (nsa.total_failed_attemps_to_connect=0)
        )
        And
        (
          (Not OnlyWhereIConnected)
          Or
          (nsa.last_connection>0)
        )
        then begin
        SetLength(Result,length(Result)+1);
        Result[high(Result)] := nsa;
      end;
    end;
  finally
    FNodeServers.UnlockList;
  end;
end;

class function TNetData.HeaderDataToText(const HeaderData: TNetHeaderData): AnsiString;
begin
  Result := CT_NetTransferType[HeaderData.header_type]+' Operation:'+TNetData.OperationToText(HeaderData.operation);
  if HeaderData.is_error then begin
    Result := Result +' ERRCODE:'+Inttostr(HeaderData.error_code)+' ERROR:'+HeaderData.error_text;
  end else begin
    Result := Result +' ReqId:'+Inttostr(HeaderData.request_id)+' BufferSize:'+Inttostr(HeaderData.buffer_data_length);
  end;
end;

procedure TNetData.IncStatistics(incActiveConnections, incClientsConnections,
  incServersConnections,incServersConnectionsWithResponse: Integer; incBytesReceived, incBytesSend: Int64);
begin
  // Multithread prevention
  FNodeServers.LockList;
  Try
    FNetStatistics.ActiveConnections := FNetStatistics.ActiveConnections + incActiveConnections;
    FNetStatistics.ClientsConnections := FNetStatistics.ClientsConnections + incClientsConnections;
    FNetStatistics.ServersConnections := FNetStatistics.ServersConnections + incServersConnections;
    FNetStatistics.ServersConnectionsWithResponse := FNetStatistics.ServersConnectionsWithResponse + incServersConnectionsWithResponse;
    if (incActiveConnections>0) then FNetStatistics.TotalConnections := FNetStatistics.TotalConnections + incActiveConnections;
    if (incClientsConnections>0) then FNetStatistics.TotalClientsConnections := FNetStatistics.TotalClientsConnections + incClientsConnections;
    if (incServersConnections>0) then FNetStatistics.TotalServersConnections := FNetStatistics.TotalServersConnections + incServersConnections;
    FNetStatistics.BytesReceived := FNetStatistics.BytesReceived + incBytesReceived;
    FNetStatistics.BytesSend := FNetStatistics.BytesSend + incBytesSend;
  Finally
    FNodeServers.UnlockList;
  End;
  NotifyStatisticsChanged;
  if (incBytesReceived<>0) Or (incBytesSend<>0) then begin
    NotifyNetConnectionUpdated;
  end;
end;

function TNetData.IndexOfNetClient(ListToSearch: TList; ip: AnsiString; port: Word; indexStart : Integer = 0): Integer;
Var P : PNodeServerAddress;
begin
  if indexStart<0 then indexStart:=0;
  for Result := indexStart to ListToSearch.Count - 1 do begin
    P := ListToSearch[Result];
    if (AnsiSameText( P^.ip,ip)) And ((port=0) Or (P^.port=port)) then exit;
  end;
  Result := -1;
end;

function TNetData.IsBlackListed(const ip: AnsiString; port: Word): Boolean;
Var l : TList;
  i : Integer;
begin
  Result := false;
  l := FBlackList.LockList;
  Try
    i := -1;
    repeat
      i := IndexOfNetClient(l,ip,port,i+1);
      if (i>=0) then begin
        Result := Not PNodeServerAddress(l[i])^.its_myself;
      end;
    until (i<0) Or (Result);
  Finally
    FBlackList.UnlockList;
  End;
end;

class function TNetData.NetData: TNetData;
begin
  result := _NetData;
end;

class function TNetData.NetDataExists: Boolean;
begin
  Result := Assigned(_NetData);
end;

function TNetData.NewRequestId: Cardinal;
begin
  Inc(FLastRequestId);
  Result := FLastRequestId;
end;

procedure TNetData.Notification(AComponent: TComponent; Operation: TOperation);
Var l : TList;
begin
  inherited;
  if Operation=OpRemove then begin
    if not (csDestroying in ComponentState) then begin
      l := ConnectionsLock;
      try
        if l.Remove(AComponent)>=0 then begin
          NotifyNetConnectionUpdated;
        end;
      finally
        ConnectionsUnlock;
      end;
    end;
  end;
end;

procedure TNetData.NotifyBlackListUpdated;
begin
  FNetDataNotifyEventsThread.FNotifyOnBlackListUpdated := true;
end;

procedure TNetData.NotifyNetConnectionUpdated;
begin
  FNetDataNotifyEventsThread.FNotifyOnNetConnectionsUpdated := true;
end;

procedure TNetData.NotifyNodeServersUpdated;
begin
  FNetDataNotifyEventsThread.FNotifyOnNodeServersUpdated := true;
end;

procedure TNetData.NotifyReceivedHelloMessage;
begin
  FNetDataNotifyEventsThread.FNotifyOnReceivedHelloMessage := true;
end;

procedure TNetData.NotifyStatisticsChanged;
begin
  FNetDataNotifyEventsThread.FNotifyOnStatisticsChanged := true;
end;

class function TNetData.OperationToText(operation: Word): AnsiString;
begin
  case operation of
    CT_NetOp_Hello : Result := 'HELLO';
    CT_NetOp_Error : Result := 'ERROR';
    CT_NetOp_GetBlocks : Result := 'GET BLOCKS';
    CT_NetOp_Message : Result := 'MESSAGE';
    CT_NetOp_GetOperationsBlock : Result := 'GET OPERATIONS BLOCK';
    CT_NetOp_NewBlock : Result := 'NEW BLOCK';
    CT_NetOp_AddOperations : Result := 'ADD OPERATIONS';
  else Result := 'UNKNOWN OPERATION '+Inttohex(operation,4);
  end;
end;

function TNetData.PendingRequestAnyTime(Sender: TNetConnection) : QWord;
var
  i : Cardinal;
  l : TList;
begin
  Result := 0;
  l := FRegisteredRequests.LockList;
  Try
    if l.Count = 0 then begin
      exit;
    end;
    for i := 0 to l.Count - 1 do begin
      if (PNetRequestRegistered(l[i])^.NetClient = Sender) then begin
        Result := PNetRequestRegistered(l[i]).SendTime;
        exit;
      end;
    end;
  Finally
    FRegisteredRequests.UnlockList;
  End;
end;

function TNetData.RequestAlive(requestId : Cardinal) : Boolean;
var
  i : Integer;
  l : TList;
begin
  Result := false;
  l := FRegisteredRequests.LockList;
  try
    for i := l.Count - 1 downto 0 do begin
      if PNetRequestRegistered(l[i])^.RequestId = requestId then
      begin
        Result := true;
        exit;
      end;
    end;
  finally
    FRegisteredRequests.UnlockList;
  end;
end;

procedure TNetData.RegisterRequest(Sender: TNetConnection; operation: Word; request_id: Cardinal);
Var P : PNetRequestRegistered;
  l : TList;
begin
  l := FRegisteredRequests.LockList;
  Try
    New(P);
    P^.NetClient := Sender;
    P^.Operation := operation;
    P^.RequestId := request_id;
    P^.SendTime := GetTickCount64;
    l.Add(P);
    TLog.NewLog(ltdebug,Classname,'Registering request to '+Sender.ClientRemoteAddr+' Op:'+OperationToText(operation)+' Id:'+inttostr(request_id)+' Total pending:'+Inttostr(l.Count));
  Finally
    FRegisteredRequests.UnlockList;
  End;
end;

procedure TNetData.SetNetConnectionsActive(const Value: Boolean);
begin
  FNetConnectionsActive := Value;
  if FNetConnectionsActive then DiscoverServers
  else DisconnectClients;
end;

function TNetData.UnRegisterRequest(Sender: TNetConnection; operation: Word; request_id: Cardinal): Boolean;
Var P : PNetRequestRegistered;
  i : Integer;
  l : TList;
begin
  Result := false;
  l := FRegisteredRequests.LockList;
  try
    for i := l.Count - 1 downto 0 do begin
      P := l[i];
      if (P^.NetClient=Sender) And
        ( ((Operation=P^.Operation) And (request_id = P^.RequestId))
          Or
          ((operation=0) And (request_id=0)) ) then begin
        l.Delete(i);
        Dispose(P);
        Result := true;
        if Assigned(Sender.FTcpIpClient) then begin
          TLog.NewLog(ltdebug,Classname,'Unregistering request to '+Sender.ClientRemoteAddr+' Op:'+OperationToText(operation)+' Id:'+inttostr(request_id)+' Total pending:'+Inttostr(l.Count));
        end else begin
          TLog.NewLog(ltdebug,Classname,'Unregistering request to (NIL) Op:'+OperationToText(operation)+' Id:'+inttostr(request_id)+' Total pending:'+Inttostr(l.Count));
        end;
      end;
    end;
  finally
    FRegisteredRequests.UnlockList;
  end;
end;

{ TNetServer }

constructor TNetServer.Create;
begin
  inherited;
  MaxConnections := CT_MaxClientsConnected;
  NetTcpIpClientClass := TNetTcpIpClient;
  Port := CT_NetServer_Port;
end;

procedure TNetServer.OnNewIncommingConnection(Sender : TObject; Client : TNetTcpIpClient);
Var n : TNetServerClient;
  DebugStep : String;
begin
  DebugStep := '';
  Try
    if Not Client.Connected then exit;
    // NOTE: I'm in a separate thread
    // While in this function the ClientSocket connection will be active, when finishes the ClientSocket will be destroyed
    TLog.NewLog(ltInfo,Classname,'Starting ClientSocket accept '+Client.ClientRemoteAddr);
    n := TNetServerClient.Create(Nil, Client);
    Try
      DebugStep := 'Assigning client';
      TNetData.NetData.IncStatistics(1,1,0,0,0,0);
      TNetData.NetData.CleanBlackList;
      DebugStep := 'Checking blacklisted';
      if (TNetData.NetData.IsBlackListed(Client.RemoteHost,0)) then begin
        // Invalid!
        TLog.NewLog(ltinfo,Classname,'Refusing Blacklist ip: '+Client.ClientRemoteAddr);
        n.SendError(ntp_autosend,CT_NetOp_Error, 0,CT_NetError_IPBlackListed,'Your IP is blacklisted:'+Client.ClientRemoteAddr);
        // Wait some time before close connection
        sleep(5000);
      end else begin
        DebugStep := 'Processing buffer and sleep...';
        while (n.Connected) And (Active) do begin
          n.DoProcessBuffer;
          n.BroadcastNewBlocksAndOperations;
          Sleep(10);
        end;
      end;
    Finally
      Try
        TLog.NewLog(ltdebug,Classname,'Finalizing ServerAccept '+IntToHex(PtrInt(n),8)+' '+n.ClientRemoteAddr);
        n.FTcpIpClient.Disconnect;
      Finally
        n.Free;
      End;
    End;
  Except
    On E:Exception do begin
      TLog.NewLog(lterror,ClassName,'Exception processing client thread at step: '+DebugStep+' - ('+E.ClassName+') '+E.Message);
    end;
  End;
end;

procedure TNetServer.SetActive(const Value: Boolean);
begin
  if Value then begin
    TLog.NewLog(ltinfo,Classname,'Activating server on port '+IntToStr(Port));
  end else begin
    TLog.NewLog(ltinfo,Classname,'Closing server');
  end;
  inherited;
  if Active then begin
    // TNode.Node.AutoDiscoverNodes(CT_Discover_IPs);
  end else if TNetData.NetDataExists then begin
    TNetData.NetData.DisconnectClients;
  end;
end;

function TNetConnection.ClientRemoteAddr: AnsiString;
begin
  Result := FTcpIpClient.ClientRemoteAddr;
end;

function TNetConnection.ConnectTo(ServerIP: AnsiString; ServerPort: Word; stop : PBoolean = Nil) : Boolean;
Var Pnsa : PNodeServerAddress;
  lns : TList;
  i : Integer;
begin
  if Client.Connected then Client.Disconnect;
  lns := TNetData.NetData.FNodeServers.LockList;
  try
    i := TNetData.NetData.IndexOfNetClient(lns,ServerIp,ServerPort);
    if (i>=0) then Pnsa := lns[i]
    else Pnsa := Nil;
    if Assigned(Pnsa) then Pnsa^.netConnection := Self;
  finally
    TNetData.NetData.FNodeServers.UnlockList;
  end;

  FNetLock.Acquire;
  Try
    if ServerPort = 0 then
    begin
      ServerPort := CT_NetServer_Port;
    end;
    TLog.NewLog(ltDebug,Classname,'Trying to connect to a server at: '+ClientRemoteAddr);
    TNetData.NetData.NotifyNetConnectionUpdated;

    Result := Client.Connect(ServerIP, ServerPort, 15, stop);
  Finally
    FNetLock.Release;
  End;
  if Result then begin
    TLog.NewLog(ltDebug,Classname,'Connected to a possible server at: '+ClientRemoteAddr);
    Result := Send_Hello(ntp_request,TNetData.NetData.NewRequestId);
  end else begin
    TLog.NewLog(ltDebug,Classname,'Cannot connect to a server at: '+ClientRemoteAddr);
  end;
end;

constructor TNetConnection.Create(AOwner: TComponent);
begin
  inherited;

  FFreeClientOnDestroy := true;
  FTcpIpClient := TNetTcpIpClient.Create(Self);
  FTcpIpClient.FreeNotification(Self);
  FTcpIpClient.OnConnect := TcpClient_OnConnect;
  FTcpIpClient.OnDisconnect := TcpClient_OnDisconnect;
  TNetData.NetData.NotifyNetConnectionUpdated;

  Initialize;
end;

constructor TNetConnection.Create(AOwner : TComponent; const client : TNetTcpIpClient);
begin
  inherited Create(AOwner);

  FFreeClientOnDestroy := false;
  FTcpIpClient := client;
  FTcpIpClient.FreeNotification(Self);
  FTcpIpClient.OnConnect := TcpClient_OnConnect;
  FTcpIpClient.OnDisconnect := TcpClient_OnDisconnect;
  TNetData.NetData.NotifyNetConnectionUpdated;

  Initialize;
end;

destructor TNetConnection.Destroy;
Var Pnsa : PNodeServerAddress;
  lns : TList;
  i : Integer;
begin
  TLog.NewLog(ltdebug,ClassName,'Destroying '+Classname+' '+IntToHex(PtrInt(Self),8));

  FTcpIpClient.Disconnect;

  lns := TNetData.NetData.FNodeServers.LockList;
  try
    for i := lns.Count - 1 downto 0 do begin
      Pnsa := lns[i];
      if Pnsa^.netConnection=Self then Begin
        Pnsa^.netConnection := Nil;
      End;
    end;
  finally
    TNetData.NetData.FNodeServers.UnlockList;
  end;
  TNetData.NetData.FNetConnections.Remove(Self);
  TNetData.NetData.UnRegisterRequest(Self,0,0);
  Try
    TNetData.NetData.NotifyNetConnectionUpdated;
  Finally
    FreeAndNil(FNetLock);
    FreeAndNil(FClientBufferRead);
    if FFreeClientOnDestroy then
    begin
      FreeAndNil(FTcpIpClient);
    end;

    with FNewOperationsList.LockList do
    begin
      try
        for i := 0 to Count - 1 do
        begin
          TOperationsHashTree(Items[i]).Free;
        end;
      finally
        FNewOperationsList.UnlockList;
      end;
    end;
    FreeAndNil(FNewOperationsList);

    inherited;
  End;
end;

procedure TNetConnection.Initialize;
begin
  FNewOperationsList := TThreadList.Create;
  FIsDownloadingBlocks := false;
  FHasReceivedData := false;
  FNetProtocolVersion.protocol_version := 0; // 0 = unknown
  FNetProtocolVersion.protocol_available := 0;
  FAlertedForNewProtocolAvailable := false;
  FDoFinalizeConnection := false;
  FClientAppVersion := '';
  FClientPublicKey := CT_TECDSA_Public_Nul;
  FCreatedTime := Now;
  FIsMyselfServer := false;
  FLastKnownTimestampDiff := 0;
  FIsWaitingForResponse := false;
  FClientBufferRead := TMemoryStream.Create;
  FNetLock := TCriticalSection.Create;
  FLastDataReceivedTS := 0;
  FLastDataSendedTS := 0;
  FRemoteOperationBlock := CT_OperationBlock_NUL;

  TNetData.NetData.FNetConnections.Add(Self);
  TNetData.NetData.NotifyNetConnectionUpdated;
end;

procedure TNetConnection.DisconnectInvalidClient(ItsMyself : Boolean; const why: AnsiString; blacklist : Boolean = true);
Var P : PNodeServerAddress;
  l : TList;
  i : Integer;
  include_in_list : Boolean;
begin
  FIsDownloadingBlocks := false;
  if ItsMyself then begin
    TLog.NewLog(ltInfo,Classname,'Disconecting myself '+ClientRemoteAddr+' > '+Why)
  end else begin
    TLog.NewLog(lterror,Classname,'Disconecting '+ClientRemoteAddr+' > '+Why);
  end;
  FIsMyselfServer := ItsMyself;
  include_in_list := blacklist and (Not SameText(Client.RemoteHost,'localhost')) And (Not SameText(Client.RemoteHost,'127.0.0.1'))
    And (Not SameText('192.168.',Copy(Client.RemoteHost,1,8)))
    And (Not SameText('10.',Copy(Client.RemoteHost,1,3)));
  if include_in_list then begin
    l := TNetData.NetData.FBlackList.LockList;
    try
      i := TNetData.NetData.IndexOfNetClient(l,Client.RemoteHost,Client.RemotePort);
      if i<0 then begin
        new(P);
        P^ := CT_TNodeServerAddress_NUL;
        l.Add(P);
      end else P := l[i];
      P^.ip := Client.RemoteHost;
      P^.port := Client.RemotePort;
      P^.last_connection := UnivDateTimeToUnix(DateTime2UnivDateTime(now));
      P^.its_myself := ItsMyself;
      P^.BlackListText := Why;
    finally
      TNetData.NetData.FBlackList.UnlockList;
    end;
  end;
  if ItsMyself then begin
    l := TNetData.NetData.FNodeServers.LockList;
    try
      i := TNetData.NetData.IndexOfNetClient(l,Client.RemoteHost,Client.RemotePort);
      if i>=0 then begin
        P := l[i];
        P^.its_myself := ItsMyself;
      end;
    finally
      TNetData.NetData.FNodeServers.UnlockList;
    end;
  end;
  FTcpIpClient.Disconnect;
  TNetData.NetData.NotifyBlackListUpdated;
  TNetData.NetData.NotifyNodeServersUpdated;
end;

Procedure TNetConnection.DoProcessBuffer;
Var HeaderData : TNetHeaderData;
  ms : TMemoryStream;
  ops : AnsiString;
  DebugStep : String;
  current : QWord;
  request : QWord;
begin
  DebugStep := '';
  try
    if FDoFinalizeConnection then begin
      DebugStep := 'Executing DoFinalizeConnection';
      TLog.NewLog(ltdebug,Classname,'Executing DoFinalizeConnection at client '+ClientRemoteAddr);
      FTcpIpClient.Disconnect;
    end;
    if Not Connected then exit;
    ms := TMemoryStream.Create;
    try
      FNetLock.Acquire;
      Try
        if Not FIsWaitingForResponse then begin
          DebugStep := 'is not waiting for response, do send';
          DoSendAndWaitForResponse(0,0,Nil,ms,5000,HeaderData);
        end else begin
          DebugStep := 'Is waiting for response, nothing';
        end;
      Finally
        FNetLock.Release;
      End;
    finally
      ms.Free;
    end;
    current := GetTickCount64;
    request := TNetData.NetData.PendingRequestAnyTime(Self);
    if (request > 0) and ((request + 30 * 1000) < current) then begin
      TLog.NewLog(ltDebug,Classname,'Pending requests without response... closing connection to '+ClientRemoteAddr+' > '+ops);
      DebugStep := 'Setting connected to false';
      FTcpIpClient.Disconnect;
    end else if (current > (FLastDataSendedTS + 120 * 1000)) then begin
      TLog.NewLog(ltDebug,Classname,'Sending Hello to check connection to '+ClientRemoteAddr+' > '+ops);
      DebugStep := 'Sending Hello';
      Send_Hello(ntp_request,TNetData.NetData.NewRequestId);
    end;
  Except
    On E:Exception do begin
      E.Message := E.Message+' Step.TNetConnection.DoProcessBuffer: '+DebugStep;
      TLog.NewLog(lterror,Classname,E.Message);
      Raise;
    end;
  end;
end;

procedure TNetConnection.DoProcess_AddOperations(HeaderData: TNetHeaderData; DataBuffer: TStream);
var c,i : Integer;
    optype : Byte;
    opclass : TPCOperationClass;
    op : TPCOperation;
    operations : TOperationsHashTree;
    errors : AnsiString;
  DoDisconnect : Boolean;
begin
  DoDisconnect := true;
  operations := TOperationsHashTree.Create;
  try
    if HeaderData.header_type<>ntp_autosend then begin
      errors := 'Not autosend';
      exit;
    end;
    if DataBuffer.Size<4 then begin
      errors := 'Invalid databuffer size';
      exit;
    end;
    DataBuffer.Read(c,4);
    for i := 1 to c do begin
      errors := 'Invalid operation '+inttostr(i)+'/'+inttostr(c);
      if not DataBuffer.Read(optype,1)=1 then exit;
      opclass := TPCOperationsComp.GetOperationClassByOpType(optype);
      if Not Assigned(opclass) then exit;
      op := opclass.Create;
      Try
        op.LoadFromStream(DataBuffer);
        operations.AddOperationToHashTree(op);
      Finally
        op.Free;
      End;
    end;
    DoDisconnect := false;
  finally
    try
      if DoDisconnect then begin
        DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
      end else begin
        TNode.Node.AddOperations(Self,operations,Nil,errors);
      end;
    finally
      operations.Free;
    end;
  end;
end;

procedure TNetConnection.DoProcess_GetBlocks_Request(HeaderData: TNetHeaderData; DataBuffer: TStream);
Var b,b_start,b_end:Cardinal;
    op : TPCOperationsComp;
    db : TMemoryStream;
    c : Cardinal;
  errors : AnsiString;
  DoDisconnect : Boolean;
  posquantity : Int64;
begin
  DoDisconnect := true;
  try
    if HeaderData.header_type<>ntp_request then begin
      errors := 'Not request';
      exit;
    end;
     // DataBuffer contains: from and to
     errors := 'Invalid structure';
     if (DataBuffer.Size-DataBuffer.Position<8) then begin
       exit;
     end;
     DataBuffer.Read(b_start,4);
     DataBuffer.Read(b_end,4);
     if (b_start<0) Or (b_start>b_end) then begin
       errors := 'Invalid structure start or end: '+Inttostr(b_start)+' '+Inttostr(b_end);
       exit;
     end;
     if (b_end>=TNetData.NetData.Bank.BlocksCount) then b_end := TNetData.NetData.Bank.BlocksCount-1;

     DoDisconnect := false;

     db := TMemoryStream.Create;
     try
       op := TPCOperationsComp.Create(TNetData.NetData.bank);
       try
         c := b_end - b_start + 1;
         posquantity := db.position;
         db.Write(c,4);
         c := 0;
         b := b_start;
         for b := b_start to b_end do begin
           inc(c);
           If TNetData.NetData.bank.LoadOperations(op,b) then begin
             op.SaveBlockToStream(false,db);
           end else begin
             SendError(ntp_response,HeaderData.operation,HeaderData.request_id,CT_NetError_InternalServerError,'Operations of block:'+inttostr(b)+' not found');
             exit;
           end;
           // Build 1.0.5 To prevent high data over net in response (Max 2 Mb of data)
           if (db.size>(1024*1024*2)) then begin
             // Stop
             db.position := posquantity;
             db.Write(c,4);
             // BUG of Build 1.0.5 !!! Need to break bucle OH MY GOD!
             db.Position := db.Size;
             break;
           end;
         end;
         Send(ntp_response,HeaderData.operation,0,HeaderData.request_id,db);
       finally
         op.Free;
       end;
     finally
       db.Free;
     end;
     TLog.NewLog(ltdebug,Classname,'Sending operations from block '+inttostr(b_start)+' to '+inttostr(b_end));
  finally
    if DoDisconnect then begin
      DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
    end;
  end;
end;

procedure TNetConnection.DoProcess_GetBlocks_Response(HeaderData: TNetHeaderData; DataBuffer: TStream);
  var op, localop : TPCOperationsComp;
    opcount,i : Cardinal;
    newBlockAccount : TBlockAccount;
  errors : AnsiString;
  DoDisconnect : Boolean;
begin
  DoDisconnect := true;
  try
    if HeaderData.header_type<>ntp_response then begin
      errors := 'Not response';
      exit;
    end;
    // DataBuffer contains: from and to
    errors := 'Invalid structure';
    op := TPCOperationsComp.Create(nil);
    Try
      op.bank := TNode.Node.Bank;
      if DataBuffer.Size-DataBuffer.Position<4 then begin
        DisconnectInvalidClient(false,'DoProcess_GetBlocks_Response invalid format: '+errors);
        exit;
      end;
      DataBuffer.Read(opcount,4);
      DoDisconnect :=false;
      for I := 1 to opcount do begin
        if Not op.LoadBlockFromStream(DataBuffer,errors) then begin
           errors := 'Error decoding block '+inttostr(i)+'/'+inttostr(opcount)+' Errors:'+errors;
           DoDisconnect := true;
           exit;
        end;
        if (op.OperationBlock.block=TNode.Node.Bank.BlocksCount) then begin
          if (TNode.Node.Bank.AddNewBlockChainBlock(op,newBlockAccount,errors, TNetData.NetData.NetworkAdjustedTime.TimeOffset)) then begin
            // Ok, one more!
          end else begin
            // Is not a valid entry????
            // Perhaps an orphan blockchain: Me or Client!
            localop := TPCOperationsComp.Create(nil);
            Try
              TNode.Node.Bank.LoadOperations(localop,TNode.Node.Bank.BlocksCount-1);
              TLog.NewLog(ltinfo,Classname,'Distinct operation block found! My:'+
                  TPCOperationsComp.OperationBlockToText(localop.OperationBlock)+' remote:'+TPCOperationsComp.OperationBlockToText(op.OperationBlock)+' Errors: '+errors);
            Finally
              localop.Free;
            End;
          end;
        end else begin
          // Receiving an unexpected operationblock
          TLog.NewLog(lterror,classname,'Received a distinct block, finalizing: '+TPCOperationsComp.OperationBlockToText(op.OperationBlock)+' (My block: '+TPCOperationsComp.OperationBlockToText(TNode.Node.Bank.LastOperationBlock)+')' );
          exit;
        end;
      end;
      if ((opcount>0) And (FRemoteOperationBlock.block>=TNode.Node.Bank.BlocksCount)) then begin
        Send_GetBlocks(TNode.Node.Bank.BlocksCount,1000,i);
      end;
      TNode.Node.NotifyBlocksChanged;
    Finally
      FIsDownloadingBlocks := false;
      op.Free;
    End;
  Finally
    if DoDisconnect then begin
      DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
    end;
  end;
end;

procedure TNetConnection.DoProcess_GetOperationsBlock_Request(HeaderData: TNetHeaderData; DataBuffer: TStream);
Const CT_Max_Positions = 10;
Var inc_b,b,b_start,b_end, total_b:Cardinal;
  op : TPCOperationsComp;
  db,msops : TMemoryStream;
  errors, blocksstr : AnsiString;
  DoDisconnect : Boolean;
begin
  blocksstr := '';
  DoDisconnect := true;
  try
    if HeaderData.header_type<>ntp_request then begin
      errors := 'Not request';
      exit;
    end;
    errors := 'Invalid structure';
    if (DataBuffer.Size-DataBuffer.Position<8) then begin
       exit;
    end;
    DataBuffer.Read(b_start,4);
    DataBuffer.Read(b_end,4);
    if (b_start<0) Or (b_start>b_end) Or (b_start>=TNode.Node.Bank.BlocksCount) then begin
      errors := 'Invalid start ('+Inttostr(b_start)+') or end ('+Inttostr(b_end)+') of count ('+Inttostr(TNode.Node.Bank.BlocksCount)+')';
      exit;
    end;

    DoDisconnect := false;

    // Build 1.4
    if b_start<TNode.Node.Bank.Storage.FirstBlock then begin
      b_start := TNode.Node.Bank.Storage.FirstBlock;
      if b_end<b_start then begin
        errors := 'Block:'+inttostr(b_end)+' not found';
        SendError(ntp_response,HeaderData.operation,HeaderData.request_id,CT_NetError_InternalServerError,errors);
        exit;
      end;
    end;


    if (b_end>=TNode.Node.Bank.BlocksCount) then b_end := TNode.Node.Bank.BlocksCount-1;
    inc_b := ((b_end - b_start) DIV CT_Max_Positions)+1;
    msops := TMemoryStream.Create;
    op := TPCOperationsComp.Create(TNode.Node.Bank);
     try
       b := b_start;
       total_b := 0;
       repeat
         If TNode.Node.bank.LoadOperations(op,b) then begin
           op.SaveBlockToStream(true,msops);
           blocksstr := blocksstr + inttostr(b)+',';
           b := b + inc_b;
           inc(total_b);
         end else begin
           errors := 'Operations of block:'+inttostr(b)+' not found';
           SendError(ntp_response,HeaderData.operation,HeaderData.request_id,CT_NetError_InternalServerError,errors);
           exit;
         end;
       until (b > b_end);
       db := TMemoryStream.Create;
       try
         db.Write(total_b,4);
         db.WriteBuffer(msops.Memory^,msops.Size);
         Send(ntp_response,HeaderData.operation,0,HeaderData.request_id,db);
       finally
         db.Free;
       end;
     finally
       msops.Free;
       op.Free;
     end;
     TLog.NewLog(ltdebug,Classname,'Sending '+inttostr(total_b)+' operations block from block '+inttostr(b_start)+' to '+inttostr(b_end)+' '+blocksstr);
  finally
    if DoDisconnect then begin
      DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
    end;
  end;
end;

procedure TNetConnection.DoProcess_Hello(HeaderData: TNetHeaderData; DataBuffer: TStream);
  Function IsValidTime(connection_ts : Cardinal) : Boolean;
  Var l : TList;
    i : Integer;
    nc : TNetConnection;
    min_valid_time,max_valid_time : Cardinal;
    showmessage : Boolean;
  Begin
    if ((FLastKnownTimestampDiff<((-1)*(CT_MaxSecondsDifferenceOfNetworkNodes DIV 2)))
        OR (FLastKnownTimestampDiff>(CT_MaxSecondsDifferenceOfNetworkNodes DIV 2))) then begin
      TLog.NewLog(ltdebug,Classname,'Processing a hello from a client with different time. Difference: '+Inttostr(FLastKnownTimestampDiff));
    end;
    min_valid_time := (UnivDateTimeToUnix(DateTime2UnivDateTime(now))-CT_MaxSecondsDifferenceOfNetworkNodes);
    max_valid_time := (UnivDateTimeToUnix(DateTime2UnivDateTime(now))+CT_MaxSecondsDifferenceOfNetworkNodes);
    If (connection_ts < min_valid_time) or (connection_ts > max_valid_time) then begin
      Result := false;
      showmessage := true;
      // This message only appears if there is no other valid connections
      l := TNetData.NetData.NetConnections.LockList;
      try
        for i := 0 to l.Count - 1 do begin
          nc :=(TNetConnection(l[i]));
          if (nc<>self) and (nc.FHasReceivedData) and (nc.Connected)
            and (nc.FLastKnownTimestampDiff>=((-1)*CT_MaxSecondsDifferenceOfNetworkNodes))
            and (nc.FLastKnownTimestampDiff<=(CT_MaxSecondsDifferenceOfNetworkNodes))
            then begin
            showmessage := false;
            break;
          end;
        end;
      finally
        TNetData.NetData.NetConnections.UnlockList;
      end;
      if showmessage then begin
        TNode.Node.NotifyNetClientMessage(Nil,'Detected a different time in an other node... check that your PC time and timezone is correct or you will be Blacklisted! '+
          'Your time: '+TimeToStr(now)+' - '+Client.ClientRemoteAddr+' time: '+TimeToStr(UnivDateTime2LocalDateTime( UnixToUnivDateTime(connection_ts)))+' Difference: '+inttostr(FLastKnownTimestampDiff)+' seconds. '+
          '(If this message appears on each connection, then you have a bad configured time, if not, do nothing)' );
      end;
    end else begin
      Result := true;
    end;
  End;
var
  op : TPCOperationsComp;
  errors : AnsiString;
  connection_has_a_server : Word;
  i,c : Integer;
  nsa : TNodeServerAddress;
  connection_ts : Cardinal;
  Duplicate : TNetConnection;
  RawAccountKey : TRawBytes;
  other_version : AnsiString;
Begin
  op := TPCOperationsComp.Create(Nil);
  try
    DataBuffer.Position:=0;
    if DataBuffer.Read(connection_has_a_server,2)<2 then begin
      DisconnectInvalidClient(false,'Invalid data on buffer: '+TNetData.HeaderDataToText(HeaderData));
      exit;
    end;
    If TStreamOp.ReadAnsiString(DataBuffer,RawAccountKey)<0 then begin
      DisconnectInvalidClient(false,'Invalid data on buffer. No Public key: '+TNetData.HeaderDataToText(HeaderData));
      exit;
    end;
    FClientPublicKey := TAccountComp.RawString2Accountkey(RawAccountKey);
    If Not TAccountComp.IsValidAccountKey(FClientPublicKey,errors) then begin
      DisconnectInvalidClient(false,'Invalid Public key: '+TNetData.HeaderDataToText(HeaderData)+' errors: '+errors);
      exit;
    end;
    if DataBuffer.Read(connection_ts,4)<4 then begin
      DisconnectInvalidClient(false,'Invalid data on buffer. No TS: '+TNetData.HeaderDataToText(HeaderData));
      exit;
    end;
    FLastKnownTimestampDiff := Int64(connection_ts) - Int64(UnivDateTimeToUnix( DateTime2UnivDateTime(now)));

    if IsValidTime(connection_ts) then begin
      TNetData.NetData.NetworkAdjustedTime.Input(self.Client.RemoteHost, FLastKnownTimestampDiff);
      if (-1) * TNetData.NetData.NetworkAdjustedTime.TimeOffset > CT_MaxSecondsFutureBlockTime then begin
        TNode.Node.NotifyNetClientMessage(Nil, Format('System time is %d seconds ahead the network time. In order to be able to mine, ensure that your system clock is set correctly.', [(-1) * TNetData.NetData.NetworkAdjustedTime.TimeOffset]));
      end;
    end else begin
      DisconnectInvalidClient(false,'Invalid remote timestamp. Difference:'+inttostr(FLastKnownTimestampDiff)+' > '+inttostr(CT_MaxSecondsDifferenceOfNetworkNodes), false);
    end;

    if (connection_has_a_server>0) And (Not SameText(Client.RemoteHost,'localhost')) And (Not SameText(Client.RemoteHost,'127.0.0.1'))
      And (Not SameText('192.168.',Copy(Client.RemoteHost,1,8)))
      And (Not SameText('10.',Copy(Client.RemoteHost,1,3)))
      And (Not TAccountComp.Equal(FClientPublicKey,TNetData.NetData.FNodePrivateKey.PublicKey)) then begin
      nsa := CT_TNodeServerAddress_NUL;
      nsa.ip := Client.RemoteHost;
      nsa.port := connection_has_a_server;
      // BUG corrected 1.1.1: nsa.last_connection_by_server := UnivDateTimeToUnix(DateTime2UnivDateTime(now));
      nsa.last_connection := UnivDateTimeToUnix(DateTime2UnivDateTime(now));
      TNetData.NetData.AddServer(nsa);
    end;

    if op.LoadBlockFromStream(DataBuffer,errors) then begin
      FRemoteOperationBlock := op.OperationBlock;
      If TNetData.NetData.Bank.BlocksCount <= FRemoteOperationBlock.block then
      begin
        TLog.NewLog(ltinfo, Classname, Format('Remote block %d. Forcing blockchain update', [FRemoteOperationBlock.block]));
        TNetData.NetData.ForceBlockchainUpdate;
      end;
      if (DataBuffer.Size-DataBuffer.Position>=4) then begin
        DataBuffer.Read(c,4);
        for i := 1 to c do begin
          nsa := CT_TNodeServerAddress_NUL;
          TStreamOp.ReadAnsiString(DataBuffer,nsa.ip);
          DataBuffer.Read(nsa.port,2);
          DataBuffer.Read(nsa.last_connection_by_server,4);
          TNetData.NetData.AddServer(nsa);
        end;
        if TStreamOp.ReadAnsiString(DataBuffer,other_version)>=0 then begin
          // Captures version
          ClientAppVersion := other_version;
        end;
      end;
      TLog.NewLog(ltdebug,Classname,'Hello received: '+TPCOperationsComp.OperationBlockToText(FRemoteOperationBlock));
      if (HeaderData.header_type in [ntp_request,ntp_response]) then begin
        // Response:
        if (HeaderData.header_type=ntp_request) then begin
          Send_Hello(ntp_response,HeaderData.request_id);
        end;
        if (TAccountComp.Equal(FClientPublicKey,TNetData.NetData.FNodePrivateKey.PublicKey)) then begin
          DisconnectInvalidClient(true,'MySelf disconnecting...');
          exit;
        end;
        Duplicate := TNetData.NetData.FindConnectionByClientRandomValue(Self);
        if (Duplicate<>Nil) And (Duplicate.Connected) then begin
          DisconnectInvalidClient(true,'Duplicate connection with '+Duplicate.ClientRemoteAddr);
          exit;
        end;

        TNetData.NetData.NotifyReceivedHelloMessage;
      end else begin
        DisconnectInvalidClient(false,'Invalid header type > '+TNetData.HeaderDataToText(HeaderData));
      end;
    end else begin
      TLog.NewLog(lterror,Classname,'Error decoding operations of HELLO: '+errors);
      DisconnectInvalidClient(false,'Error decoding operations of HELLO: '+errors);
    end;
  finally
    op.Free;
  end;
end;

procedure TNetConnection.DoProcess_Message(HeaderData: TNetHeaderData; DataBuffer: TStream);
Var   errors : AnsiString;
  decrypted,messagecrypted : AnsiString;
  DoDisconnect : boolean;
begin
  errors := '';
  DoDisconnect := true;
  try
    if HeaderData.header_type<>ntp_autosend then begin
      errors := 'Not autosend';
      exit;
    end;
    If TStreamOp.ReadAnsiString(DataBuffer,messagecrypted)<0 then begin
      errors := 'Invalid message data';
      exit;
    end;
    If Not ECIESDecrypt(TNetData.NetData.FNodePrivateKey.EC_OpenSSL_NID,TNetData.NetData.FNodePrivateKey.PrivateKey,false,messagecrypted,decrypted) then begin
      errors := 'Error on decrypting message';
      exit;
    end;

    DoDisconnect := false;
    if TCrypto.IsHumanReadable(decrypted) then
      TLog.NewLog(ltinfo,Classname,'Received new message from '+ClientRemoteAddr+' Message ('+inttostr(length(decrypted))+' bytes): '+decrypted)
    else
      TLog.NewLog(ltinfo,Classname,'Received new message from '+ClientRemoteAddr+' Message ('+inttostr(length(decrypted))+' bytes) in hexadecimal: '+TCrypto.ToHexaString(decrypted));
    Try
      TNode.Node.NotifyNetClientMessage(Self,decrypted);
    Except
      On E:Exception do begin
        TLog.NewLog(lterror,Classname,'Error processing received message. '+E.ClassName+' '+E.Message);
      end;
    end;
  finally
    if DoDisconnect then begin
      DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
    end;
  end;
end;

procedure TNetConnection.DoProcess_NewBlock(HeaderData: TNetHeaderData; DataBuffer: TStream);
var bacc : TBlockAccount;
    op : TPCOperationsComp;
  errors : AnsiString;
  DoDisconnect : Boolean;
begin
  errors := '';
  DoDisconnect := true;
  try
    if HeaderData.header_type<>ntp_autosend then begin
      errors := 'Not autosend';
      exit;
    end;
    op := TPCOperationsComp.Create(nil);
    try
      op.bank := TNode.Node.Bank;
      if Not op.LoadBlockFromStream(DataBuffer,errors) then begin
        errors := 'Error decoding new account: '+errors;
        exit;
      end else begin
        DoDisconnect := false;
        FRemoteOperationBlock := op.OperationBlock;

        TLog.NewLog(ltInfo, Classname, Format('NewBlock from %s. Block: %d', [ClientRemoteAddr, FRemoteOperationBlock.block]));

        if (op.OperationBlock.block>TNode.Node.Bank.BlocksCount) then begin
          TNetData.NetData.ForceBlockchainUpdate;
        end else if (op.OperationBlock.block=TNode.Node.Bank.BlocksCount) then begin
          // New block candidate:
          If Not TNode.Node.AddNewBlockChain(Self,op,bacc,errors) then begin
            // Received a new invalid block... perhaps I'm an orphan blockchain
            TNetData.NetData.ForceBlockchainUpdate;
          end;
        end;
      end;
    finally
      op.Free;
    end;
  finally
    if DoDisconnect then begin
      DisconnectInvalidClient(false,errors+' > '+TNetData.HeaderDataToText(HeaderData)+' BuffSize: '+inttostr(DataBuffer.Size));
    end;
  end;
end;

function TNetConnection.DoSendAndWaitForResponse(operation: Word;
  RequestId: Integer; SendDataBuffer, ReceiveDataBuffer: TStream;
  MaxWaitTime: Cardinal; var HeaderData: TNetHeaderData): Boolean;
var tc : Cardinal;
  was_waiting_for_response : Boolean;
  l : TList;
  i : Integer;
begin
  Result := false;
  HeaderData := CT_NetHeaderData;
  If FIsWaitingForResponse then begin
    TLog.NewLog(ltdebug,Classname,'Is waiting for response ...');
    exit;
  end;
  If Not Assigned(FTcpIpClient) then exit;
  if Not Client.Connected then exit;
  FNetLock.Acquire;
  Try
    was_waiting_for_response := RequestId>0;
    try
      if was_waiting_for_response then begin
        FIsWaitingForResponse := true;
        Send(ntp_request,operation,0,RequestId,SendDataBuffer);
      end;
      tc := GetTickCount;
      Repeat
        if (ReadTcpClientBuffer(MaxWaitTime,HeaderData,ReceiveDataBuffer)) then begin
          l := TNetData.NetData.NodeServers.LockList;
          try
            for i := 0 to l.Count - 1 do begin
              If PNodeServerAddress( l[i] )^.netConnection=Self then begin
                PNodeServerAddress( l[i] )^.last_connection := (UnivDateTimeToUnix(DateTime2UnivDateTime(now)));
                PNodeServerAddress( l[i] )^.total_failed_attemps_to_connect := 0;
              end;
            end;
          finally
            TNetData.netData.NodeServers.UnlockList;
          end;
          TLog.NewLog(ltDebug,Classname,'Received '+CT_NetTransferType[HeaderData.header_type]+' operation:'+TNetData.OperationToText(HeaderData.operation)+' id:'+Inttostr(HeaderData.request_id)+' Buffer size:'+Inttostr(HeaderData.buffer_data_length) );
          if (RequestId=HeaderData.request_id) And (HeaderData.header_type=ntp_response) then begin
            Result := true;
          end else begin
            case HeaderData.operation of
              CT_NetOp_Hello : Begin
                DoProcess_Hello(HeaderData,ReceiveDataBuffer);
              End;
              CT_NetOp_Message : Begin
                DoProcess_Message(HeaderData,ReceiveDataBuffer);
              End;
              CT_NetOp_GetBlocks : Begin
                if HeaderData.header_type=ntp_request then
                  DoProcess_GetBlocks_Request(HeaderData,ReceiveDataBuffer)
                else if HeaderData.header_type=ntp_response then
                  DoProcess_GetBlocks_Response(HeaderData,ReceiveDataBuffer)
                else DisconnectInvalidClient(false,'Not resquest or response: '+TNetData.HeaderDataToText(HeaderData));
              End;
              CT_NetOp_GetOperationsBlock : Begin
                if HeaderData.header_type=ntp_request then
                  DoProcess_GetOperationsBlock_Request(HeaderData,ReceiveDataBuffer)
                else TLog.NewLog(ltdebug,Classname,'Received old response of: '+TNetData.HeaderDataToText(HeaderData));
              End;
              CT_NetOp_NewBlock : Begin
                DoProcess_NewBlock(HeaderData,ReceiveDataBuffer);
              End;
              CT_NetOp_AddOperations : Begin
                DoProcess_AddOperations(HeaderData,ReceiveDataBuffer);
              End;
            else
              DisconnectInvalidClient(false,'Invalid operation: '+TNetData.HeaderDataToText(HeaderData));
            end;
          end;
        end else sleep(1);
      Until (Result) Or (GetTickCount>(MaxWaitTime+tc));
    finally
      if was_waiting_for_response then FIsWaitingForResponse := false;
    end;
  Finally
    FNetLock.Release;
  End;
end;

procedure TNetConnection.FinalizeConnection;
begin
  If FDoFinalizeConnection then exit;
  TLog.NewLog(ltdebug,ClassName,'Executing FinalizeConnection to '+ClientRemoteAddr);
  FDoFinalizeConnection := true;
end;

procedure TNetConnection.QueueNewBlockBroadcast;
begin
  FNewBlocksUpdatesWaiting := true;
end;

procedure TNetConnection.QueueNewOperationBroadcast(MakeACopyOfOperationsHashTree : TOperationsHashTree);
var
  operationsHashTree : TOperationsHashTree;
begin
  operationsHashTree := TOperationsHashTree.Create;
  operationsHashTree.CopyFromHashTree(MakeACopyOfOperationsHashTree);

  FNewOperationsList.Add(operationsHashTree);
end;

procedure TNetConnection.BroadcastNewBlocksAndOperations;
var
  list : TList;
  operationsHashTree : TOperationsHashTree;
begin
  if FNewBlocksUpdatesWaiting then
  begin
    FNewBlocksUpdatesWaiting := false;
    FNetLock.Acquire;
    try
      TLog.NewLog(ltdebug, ClassName, 'Sending new block found to ' + Client.ClientRemoteAddr);
      Send_NewBlockFound;
      if TNode.Node.Operations.OperationsHashTree.OperationsCount > 0 then begin
         TLog.NewLog(ltdebug, ClassName, 'Sending ' + inttostr(TNode.Node.Operations.OperationsHashTree.OperationsCount)+' sanitized operations to '+ Client.ClientRemoteAddr);
         Send_AddOperations(TNode.Node.Operations.OperationsHashTree);
      end;
    finally
      FNetLock.Release;
    end;
  end;

  while true do
  begin
    operationsHashTree := nil;
    list := FNewOperationsList.LockList;
    try
      if list.Count > 0 then
      begin
        operationsHashTree := list.First;
        list.Remove(operationsHashTree);
      end;
    finally
      FNewOperationsList.UnlockList;
    end;

    if not Assigned(operationsHashTree) then
    begin
      break;
    end;

    FNetLock.Acquire;
    try
      if operationsHashTree.OperationsCount > 0 then
      begin
        TLog.NewLog(ltdebug, ClassName, 'Sending ' + inttostr(operationsHashTree.OperationsCount) + ' Operations to ' + ClientRemoteAddr);
        Send_AddOperations(operationsHashTree);
      end;
    finally
      FNetLock.Release;
      operationsHashTree.Free;
    end;
  end;

end;

function TNetConnection.RefAdd : Boolean;
begin
  InterLockedIncrement(FRefCount);
  if not FDoFinalizeConnection then
  begin
    Result := true;
    exit;
  end;

  InterLockedDecrement(FRefCount);
  Result := false;
end;

procedure TNetConnection.RefDec;
begin
  InterLockedDecrement(FRefCount);
end;

function TNetConnection.GetConnected: Boolean;
begin
  Result := Assigned(FTcpIpClient) And (FTcpIpClient.Connected);
end;

procedure TNetConnection.Notification(AComponent: TComponent; Operation: TOperation);
begin
  inherited;
  if (Operation=opRemove) And (AComponent = FTcpIpClient) then begin
    FTcpIpClient := Nil;
  end;
end;

function TNetConnection.ReadTcpClientBuffer(MaxWaitMiliseconds: Cardinal; var HeaderData: TNetHeaderData; BufferData: TStream): Boolean;
var
  auxstream : TMemoryStream;
  tc : QWord;
  last_bytes_read, t_bytes_read : Int64;
  IsValidHeaderButNeedMoreData : Boolean;
  deletedBytes : Int64;
begin
  t_bytes_read := 0;
  Result := false;
  HeaderData := CT_NetHeaderData;
  BufferData.Size := 0;
  FNetLock.Acquire;
  try
    tc := GetTickCount;
    repeat
      If not Connected then exit;
      if Not Client.Connected then exit;
      last_bytes_read := 0;
      FClientBufferRead.Position := 0;
      Result := TNetData.ExtractHeaderInfo(FClientBufferRead,HeaderData,BufferData,IsValidHeaderButNeedMoreData);
      if Result then begin
        FNetProtocolVersion := HeaderData.protocol;
        // Build 1.0.4 accepts net protocol 1 and 2
        if HeaderData.protocol.protocol_version>CT_NetProtocol_Available then begin
          TNode.Node.NotifyNetClientMessage(Nil,'Detected a higher Net protocol version at '+
            ClientRemoteAddr+' (v '+inttostr(HeaderData.protocol.protocol_version)+' '+inttostr(HeaderData.protocol.protocol_available)+') '+
            '... check that your version is Ok! Visit official download website for possible updates: https://sourceforge.net/projects/pascalcoin/');
          DisconnectInvalidClient(false,Format('Invalid Net protocol version found: %d available: %d',[HeaderData.protocol.protocol_version,HeaderData.protocol.protocol_available]));
          Result := false;
          exit;
        end else begin
          if (FNetProtocolVersion.protocol_available>CT_NetProtocol_Available) And (Not FAlertedForNewProtocolAvailable) then begin
            FAlertedForNewProtocolAvailable := true;
            TNode.Node.NotifyNetClientMessage(Nil,'Detected a new Net protocol version at '+
              ClientRemoteAddr+' (v '+inttostr(HeaderData.protocol.protocol_version)+' '+inttostr(HeaderData.protocol.protocol_available)+') '+
              '... Visit official download website for possible updates: https://sourceforge.net/projects/pascalcoin/');
          end;
          // Remove data from buffer and save only data not processed (higher than stream.position)
          auxstream := TMemoryStream.Create;
          try
            if FClientBufferRead.Position<FClientBufferRead.Size then begin
              auxstream.CopyFrom(FClientBufferRead,FClientBufferRead.Size-FClientBufferRead.Position);
            end;
            FClientBufferRead.Size := 0;
            FClientBufferRead.CopyFrom(auxstream,0);
          finally
            auxstream.Free;
          end;
        end;
      end else begin
        if Not Client.WaitForData(MaxWaitMiliseconds) then begin
          exit;
        end;

        FClientBufferRead.Position := FClientBufferRead.Size;
        last_bytes_read := Client.Recv(FClientBufferRead);
        if last_bytes_read > 0 then begin
          FLastDataReceivedTS := GetTickCount64;

          FClientBufferRead.Position := 0;
          inc(t_bytes_read,last_bytes_read);
        end;
      end;
    until (Result) Or ((GetTickCount64 > (tc+MaxWaitMiliseconds)) And (last_bytes_read=0));
  finally
    Try
      if (Connected) then begin
        if (Not Result) And (FClientBufferRead.Size>0) And (Not IsValidHeaderButNeedMoreData) then begin
          deletedBytes := FClientBufferRead.Size;
          TLog.NewLog(lterror,ClassName,Format('Deleting %d bytes from TcpClient buffer of %s after max %d miliseconds. Passed: %d',
            [deletedBytes, Client.ClientRemoteAddr,MaxWaitMiliseconds,GetTickCount64-tc]));
          FClientBufferRead.Size:=0;
          DisconnectInvalidClient(false,'Invalid data received in buffer ('+inttostr(deletedBytes)+' bytes)');
        end;
      end;
    Finally
      FNetLock.Release;
    End;
  end;
  if t_bytes_read>0 then begin
    if Not FHasReceivedData then begin
      FHasReceivedData := true;
      if (Self is TNetClient) then
        TNetData.NetData.IncStatistics(0,0,0,1,t_bytes_read,0)
      else TNetData.NetData.IncStatistics(0,0,0,0,t_bytes_read,0);
    end else begin
      TNetData.NetData.IncStatistics(0,0,0,0,t_bytes_read,0);
    end;
  end;
  if (Result) And (HeaderData.header_type=ntp_response) then begin
    TNetData.NetData.UnRegisterRequest(Self,HeaderData.operation,HeaderData.request_id);
  end;
end;

procedure TNetConnection.Send(NetTranferType: TNetTransferType; operation, errorcode: Word; request_id: Integer; DataBuffer: TStream);
Var l : Cardinal;
   w : Word;
  Buffer : TMemoryStream;
  s : AnsiString;
begin
  Buffer := TMemoryStream.Create;
  try
    l := CT_MagicNetIdentification;
    Buffer.Write(l,4);
    case NetTranferType of
      ntp_request: begin
        w := CT_MagicRequest;
        Buffer.Write(w,2);
        Buffer.Write(operation,2);
        w := 0;
        Buffer.Write(w,2);
        Buffer.Write(request_id,4);
      end;
      ntp_response: begin
        w := CT_MagicResponse;
        Buffer.Write(w,2);
        Buffer.Write(operation,2);
        Buffer.Write(errorcode,2);
        Buffer.Write(request_id,4);
      end;
      ntp_autosend: begin
        w := CT_MagicAutoSend;
        Buffer.Write(w,2);
        Buffer.Write(operation,2);
        w := errorcode;
        Buffer.Write(w,2);
        l := 0;
        Buffer.Write(l,4);
      end
    else
      raise Exception.Create('Invalid encoding');
    end;
    l := CT_NetProtocol_Version;
    Buffer.Write(l,2);
    l := CT_NetProtocol_Available;
    Buffer.Write(l,2);
    if Assigned(DataBuffer) then begin
      l := DataBuffer.Size;
      Buffer.Write(l,4);
      DataBuffer.Position := 0;
      Buffer.CopyFrom(DataBuffer,DataBuffer.Size);
      s := '(Data:'+inttostr(DataBuffer.Size)+'b) ';
    end else begin
      l := 0;
      Buffer.Write(l,4);
      s := '';
    end;
    Buffer.Position := 0;
    FNetLock.Acquire;
    Try
      TLog.NewLog(ltDebug,Classname,'Sending: '+CT_NetTransferType[NetTranferType]+' operation:'+
        TNetData.OperationToText(operation)+' id:'+Inttostr(request_id)+' errorcode:'+InttoStr(errorcode)+
        ' Size:'+InttoStr(Buffer.Size)+'b '+s+'to '+
        ClientRemoteAddr);
      Client.Send(Buffer.Memory, Buffer.Size);
      FLastDataSendedTS := GetTickCount64;
    Finally
      FNetLock.Release;
    End;
    TNetData.NetData.IncStatistics(0,0,0,0,0,Buffer.Size);
  finally
    Buffer.Free;
  end;
end;

procedure TNetConnection.SendError(NetTranferType: TNetTransferType; operation, request_id, error_code: Integer; error_text: AnsiString);
var buffer : TStream;
begin
  buffer := TMemoryStream.Create;
  Try
    TStreamOp.WriteAnsiString(buffer,error_text);
    Send(NetTranferType,operation,error_code,request_id,buffer);
  Finally
    buffer.Free;
  End;
end;

function TNetConnection.Send_AddOperations(Operations : TOperationsHashTree) : Boolean;
var
  data : TMemoryStream;
  c1, request_id : Cardinal;
  i : Integer;
  optype : Byte;
begin
  Result := false;
  data := TMemoryStream.Create;
  try
    request_id := TNetData.NetData.NewRequestId;
    c1 := Operations.OperationsCount;
    data.Write(c1,4);
    for i := 0 to Operations.OperationsCount-1 do begin
      optype := Operations.GetOperation(i).OpType;
      data.Write(optype,1);
      Operations.GetOperation(i).SaveToStream(data);
    end;
    Send(ntp_autosend,CT_NetOp_AddOperations,0,request_id,data);
    Result := Connected;
  finally
    data.Free;
  end;
end;

function TNetConnection.Send_GetBlocks(StartAddress, quantity : Cardinal; var request_id : Cardinal) : Boolean;
Var data : TMemoryStream;
  c1,c2 : Cardinal;
begin
  Result := false;
  request_id := 0;
  if (FRemoteOperationBlock.block<TNetData.NetData.Bank.BlocksCount) Or (FRemoteOperationBlock.block=0) then exit;
  // First receive operations from
  data := TMemoryStream.Create;
  try
    if TNetData.NetData.Bank.BlocksCount=0 then c1:=0
    else c1:=StartAddress;
    if (quantity=0) then begin
      if FRemoteOperationBlock.block>0 then c2 := FRemoteOperationBlock.block
      else c2 := c1+100;
    end else c2 := c1+quantity-1;
    // Build 1.0.5 BUG - Always query for ONLY 1 if Build is lower or equal to 1.0.5
    if ((FClientAppVersion='') Or ( (length(FClientAppVersion)=5) And (FClientAppVersion<='1.0.5') )) then begin
      c2 := c1;
    end;
    data.Write(c1,4);
    data.Write(c2,4);
    request_id := TNetData.NetData.NewRequestId;
    TNetData.NetData.RegisterRequest(Self,CT_NetOp_GetBlocks,request_id);
    TLog.NewLog(ltdebug,ClassName,Format('Send GET BLOCKS start:%d quantity:%d (from:%d to %d)',[StartAddress,quantity,StartAddress,quantity+StartAddress]));
    FIsDownloadingBlocks := quantity>1;
    Send(ntp_request,CT_NetOp_GetBlocks,0,request_id,data);
    Result := Connected;
  finally
    data.Free;
  end;
end;

function TNetConnection.Send_Hello(NetTranferType : TNetTransferType; request_id : Integer) : Boolean;
  { HELLO command:
    - Operation stream
    - My Active server port (0 if no active). (2 bytes)
    - A Random Longint (4 bytes) to check if its myself connection to my server socket
    - My Unix Timestamp (4 bytes)
    - Registered node servers count
      (For each)
      - ip (string)
      - port (2 bytes)
      - last_connection UTS (4 bytes)
    - My Server port (2 bytes)
    - If this is a response:
      - If remote operation block is lower than me:
        - Send My Operation Stream in the same block thant requester
      }
var data : TStream;
  i : Integer;
  op : TPCOperationsComp;
  nsa : TNodeServerAddress;
  nsarr : TNodeServerAddressArray;
  w : Word;
  currunixtimestamp : Cardinal;
begin
  Result := false;
  if Not Connected then exit;
  // Send Hello command:
  data := TMemoryStream.Create;
  try
    if NetTranferType=ntp_request then begin
      TNetData.NetData.RegisterRequest(Self,CT_NetOp_Hello,request_id);
    end;
    If TNode.Node.NetServer.Active then
      w := TNode.Node.NetServer.Port
    else w := 0;
    // Save active server port (2 bytes). 0 = No active server port
    data.Write(w,2);
    // Save My connection public key
    TStreamOp.WriteAnsiString(data,TAccountComp.AccountKey2RawString(TNetData.NetData.FNodePrivateKey.PublicKey));
    // Save my Unix timestamp (4 bytes)
    currunixtimestamp := UnivDateTimeToUnix(DateTime2UnivDateTime(now));
    data.Write(currunixtimestamp,4);
    // Save last operations block
    op := TPCOperationsComp.Create(nil);
    try
      if (TNode.Node.Bank.BlocksCount>0) then TNode.Node.Bank.LoadOperations(op,TNode.Node.Bank.BlocksCount-1);
      op.SaveBlockToStream(true,data);
      nsarr := TNetData.NetData.GetValidNodeServers(true);
      i := length(nsarr);
      data.Write(i,4);
      for i := 0 to High(nsarr) do begin
        nsa := nsarr[i];
        TStreamOp.WriteAnsiString(data, nsa.ip);
        data.Write(nsa.port,2);
        data.Write(nsa.last_connection,4);
      end;
      // Send client version
      TStreamOp.WriteAnsiString(data,CT_ClientAppVersion{$IFDEF LINUX}+'l'{$ELSE}+'w'{$ENDIF}{$IFDEF FPC}{$IFDEF LCL}+'L'{$ELSE}+'F'{$ENDIF}{$ENDIF});
    finally
      op.free;
    end;
    //
    Send(NetTranferType,CT_NetOp_Hello,0,request_id,data);
    Result := Client.Connected;
  finally
    data.Free;
  end;
end;

function TNetConnection.Send_Message(const TheMessage: AnsiString): Boolean;
Var data : TStream;
  cyp : TRawBytes;
begin
  Result := false;
  if Not Connected then exit;
  data := TMemoryStream.Create;
  Try
    // Cypher message:
    cyp := ECIESEncrypt(FClientPublicKey,TheMessage);
    TStreamOp.WriteAnsiString(data,cyp);
    Send(ntp_autosend,CT_NetOp_Message,0,0,data);
    Result := true;
  Finally
    data.Free;
  End;
end;

function TNetConnection.Send_NewBlockFound: Boolean;
var data : TStream;
  request_id : Integer;
  op : TPCOperationsComp;
begin
  Result := false;
  if TNetData.NetData.Bank.BlocksCount=0 then exit;
  if Connected then begin
    // Checking if operationblock is the same to prevent double messaging...
    If (TPCOperationsComp.EqualsOperationBlock(FRemoteOperationBlock,TNode.Node.Bank.LastOperationBlock)) then exit;
    // Send Hello command:
    data := TMemoryStream.Create;
    try
      request_id := TNetData.NetData.NewRequestId;
      op := TPCOperationsComp.Create(nil);
      try
        op.bank := TNetData.NetData.Bank;
        if Not TNetData.NetData.Bank.LoadOperations(op,TNetData.NetData.Bank.BlocksCount-1) then begin
          TLog.NewLog(lterror,Classname,'Error on Send_NewBlockFound. Cannot load BlockOperations '+inttostr(TNetData.NetData.Bank.BlocksCount-1));
          exit;
        end;
        op.SaveBlockToStream(false,data);
        Send(ntp_autosend,CT_NetOp_NewBlock,0,request_id,data);
      finally
        op.free;
      end;
    finally
      data.Free;
    end;
    Result := Connected;
  end;
end;

procedure TNetConnection.TcpClient_OnConnect(Sender: TObject);
begin
  TNetData.NetData.IncStatistics(1,0,1,0,0,0);
  TLog.NewLog(ltInfo,Classname,'Connected to a server '+ClientRemoteAddr);
  TNetData.NetData.NotifyNetConnectionUpdated;
end;

procedure TNetConnection.TcpClient_OnDisconnect(Sender: TObject);
begin
  if self is TNetServerClient then TNetData.NetData.IncStatistics(-1,-1,0,0,0,0)
  else begin
    if FHasReceivedData then TNetData.NetData.IncStatistics(-1,0,-1,-1,0,0)
    else TNetData.NetData.IncStatistics(-1,0,-1,0,0,0);
  end;
  TLog.NewLog(ltInfo,Classname,'Disconnected from '+ClientRemoteAddr);
  TNetData.NetData.NotifyNetConnectionUpdated;
end;

procedure TNetClientThread.Execute;
begin
  while (Not Terminated) do begin
    If FNetClient.Connected then begin
      FNetClient.DoProcessBuffer;
      FNetClient.BroadcastNewBlocksAndOperations;
    end;
    Sleep(1);
  end;
end;

constructor TNetClientThread.Create(NetClient: TNetClient; AOnTerminateThread : TNotifyEvent);
begin
  FNetClient := NetClient;
  inherited Create(false);
  OnTerminate := AOnTerminateThread;
end;

{ TNetClient }

constructor TNetClient.Create(AOwner: TComponent);
begin
  inherited;
  FNetClientThread := TNetClientThread.Create(Self,OnNetClientThreadTerminated);
  FNetClientThread.FreeOnTerminate := false;
end;

destructor TNetClient.Destroy;
begin
  TLog.NewLog(ltdebug,Classname,'Starting TNetClient.Destroy');
  TNetData.NetData.FNetConnections.Remove(Self);
  FNetClientThread.OnTerminate := Nil;
  if Not FNetClientThread.Terminated then begin
    FNetClientThread.Terminate;
    FNetClientThread.WaitFor;
  end;
  FreeAndNil(FNetClientThread);
  inherited;
end;

procedure TNetClient.OnNetClientThreadTerminated(Sender: TObject);
begin
  // Close connection
  if TNetData.NetData.ConnectionExistsAndActive(Self) then begin
    FTcpIpClient.Disconnect;
  end;
end;

procedure TThreadDiscoverConnection.Execute;
Var NC : TNetClient;
  ok : Boolean;
  lns : TList;
  i : Integer;
  Pnsa : PNodeServerAddress;
begin
  try
    TLog.NewLog(ltInfo,Classname,'Starting discovery of connection '+FNodeServerAddress.ip+':'+InttoStr(FNodeServerAddress.port));

    ok := false;

    Pnsa := Nil;
    // Register attempt
    lns := TNetData.NetData.FNodeServers.LockList;
    try
      i := TNetData.NetData.IndexOfNetClient(lns,FNodeServerAddress.ip,FNodeServerAddress.port);
      if i>=0 then begin
        Pnsa := PNodeServerAddress(lns[i]);
        Pnsa.last_attempt_to_connect := Now;
        Inc(Pnsa.total_failed_attemps_to_connect);
      end;
    finally
      TNetData.NetData.FNodeServers.UnlockList;
    end;
    TNetData.NetData.NotifyNodeServersUpdated;
    // Try to connect
    NC := TNetClient.Create(Nil);
    if (FNetData.FSocks5Address <> '') and (FNetData.FSocks5Port <> 0) then
    begin
      NC.FTcpIpClient.SetSocks5(FNetData.FSocks5Address, FNetData.FSocks5Port);
    end;
    Try
      If NC.ConnectTo(FNodeServerAddress.ip, FNodeServerAddress.port, @Terminated) then begin
        ok := NC.Connected;
      end;
    Finally
      if not ok then begin
        NC.FinalizeConnection;
      end;
    End;
    TNetData.NetData.NotifyNodeServersUpdated;

    FNetData.NotifyNodeServersUpdated;

    if ok then begin
      FNetData.ForceBlockchainUpdate;
    end;
  finally
    FNetData.FDiscoveringThreads.Remove(Self);
    InterLockedDecrement(FNetData.FDiscoveringThreadsCount);
  end;
end;

constructor TThreadDiscoverConnection.Create(NodeServerAddress: TNodeServerAddress; netData : TNetData);
begin
  FNodeServerAddress := NodeServerAddress;
  FNetData := netData;
  FreeOnTerminate := true;
  inherited Create(false);
end;

procedure TThreadCheckConnections.Execute;
Var l : TList;
  i, nactive,ndeleted,nserverclients : Integer;
  netconn : TNetConnection;
  netserverclientstop : TNetServerClient;
  aux : AnsiString;
  needother : Boolean;
  newstats : TNetStatistics;
begin
  FLastCheckTS := GetTickCount64;
  while (Not Terminated) do begin
    if ((GetTickCount64 > (FLastCheckTS+1000)) AND (Not FNetData.IsDiscoveringServers)) then begin
      nactive := 0;
      ndeleted := 0;
      nserverclients := 0;
      netserverclientstop := Nil;
      needother := true;
      FLastCheckTS := GetTickCount64;
      If (FNetData.FNetConnections.TryLockList(100,l)) then begin
        try
          newstats := CT_TNetStatistics_NUL;
          for i := l.Count-1 downto 0 do begin
            netconn := TNetConnection(l.Items[i]);
            if (netconn is TNetClient) then begin
              if (netconn.Connected) then begin
                inc(newstats.ServersConnections);
                if (netconn.FHasReceivedData) then inc(newstats.ServersConnectionsWithResponse);
              end;
              if (Not TNetClient(netconn).Connected) And (netconn.CreatedTime+EncodeTime(0,0,5,0)<now) then begin
                // Free this!
                TNetClient(netconn).FinalizeConnection;
                inc(ndeleted);
              end else inc(nactive);
            end else if (netconn is TNetServerClient) then begin
              if (netconn.Connected) then begin
                inc(newstats.ClientsConnections);
              end;
              inc(nserverclients);
              if (Not netconn.FDoFinalizeConnection) then begin
                // Build 1.0.9 BUG-101 Only disconnect old versions prior to 1.0.9
                if not assigned(netserverclientstop) then begin
                  netserverclientstop := TNetServerClient(netconn);
                  aux := Copy(netconn.FClientAppVersion,1,5);
                  needother := Not ((aux='1.0.6') or (aux='1.0.7') or (aux='1.0.8'));
                end else begin
                  aux := Copy(netconn.FClientAppVersion,1,5);
                  if ((aux='1.0.6') or (aux='1.0.7') or (aux='1.0.8'))
                    And ((needother) Or (netconn.CreatedTime<netserverclientstop.CreatedTime)) then begin
                    needother := false;
                    netserverclientstop := TNetServerClient(netconn);
                  end;
                end;
              end;
            end;
          end;
          // Update stats:
          FNetData.FNetStatistics.ActiveConnections := newstats.ClientsConnections + newstats.ServersConnections;
          FNetData.FNetStatistics.ClientsConnections := newstats.ClientsConnections;
          FNetData.FNetStatistics.ServersConnections := newstats.ServersConnections;
          FNetData.FNetStatistics.ServersConnectionsWithResponse := newstats.ServersConnectionsWithResponse;
          // Must stop clients?
          if (nserverclients>CT_MaxServersConnected) And // This is to ensure there are more serverclients than clients
             ((nserverclients + nactive + ndeleted)>=CT_MaxClientsConnected) And (Assigned(netserverclientstop)) then begin
            TLog.NewLog(ltinfo,Classname,Format('Sending FinalizeConnection NetServerClients:%d Servers_active:%d Servers_deleted:%d',[nserverclients,nactive,ndeleted]));
            netserverclientstop.FinalizeConnection;
          end;
        finally
          FNetData.ConnectionsUnlock;
        end;
        if (nactive<=CT_MaxServersConnected) And (Not Terminated) then begin
          // Discover
          FNetData.DiscoverServers;
        end;
      end;
    end;
    sleep(100);
  end;
end;

constructor TThreadCheckConnections.Create(NetData: TNetData);
begin
  FNetData := NetData;
  inherited Create(false);
end;

constructor TThreadGetNewBlockChainFromClient.Create(netData : TNetData);
begin
  FNetData := netData;
  inherited Create(false);
end;

procedure TThreadGetNewBlockChainFromClient.Execute;
var
  i : Integer;
  candidates : TList;
  netConnectionsList : TList;
  nc : TNetConnection;
  lastRequestId : Cardinal;
  downloading : Boolean;
  connection : TNetConnection;
begin

  while true do
  begin
    while InterLockedExchange(FNetData.FBlockChainUpdateRequests, 0) = 0 do
    begin
      RTLeventWaitFor(FNetData.FBlockChainUpdateEvent);
      RTLeventResetEvent(FNetData.FBlockChainUpdateEvent);
    end;

    if Terminated then begin
      break;
    end;

    // Search better candidates:
    candidates := TList.Create;
    try
      netConnectionsList := FNetData.ConnectionsLock;
      Try
        downloading := false;
        for i := 0 to netConnectionsList.Count - 1 do begin
          nc := TNetConnection(netConnectionsList[i]);
          if (not nc.Connected) or (nc.FRemoteOperationBlock.block = 0) then
          begin
            continue;
          end;
          if nc.FIsDownloadingBlocks then
          begin
            downloading := true;
            break;
          end;
          if nc.FRemoteOperationBlock.block >= TNode.Node.Bank.BlocksCount then
          begin
            candidates.Add(nc);
          end;
        end;
        TLog.NewLog(ltdebug, Classname, Format('Candidates: %d Downloading: %s', [candidates.Count, BoolToStr(downloading, 'Yes', 'No')]));

        if downloading or (candidates.Count = 0) then
        begin
          continue;
        end;

        connection := TNetConnection(candidates[Random(candidates.Count)]);
        if not connection.RefAdd then
        begin
          Continue;
        end;
      finally
        FNetData.ConnectionsUnlock;
      end;

      FNetData.FMaxRemoteOperationBlock := connection.FRemoteOperationBlock;

      TLog.NewLog(ltdebug, Classname, Format('Receiving new blockchain from %s. Remote blocks: %d, Node blocks: %d', [connection.ClientRemoteAddr, connection.FRemoteOperationBlock.block, TNode.Node.Bank.BlocksCount]));

      lastRequestId := 0;
      FNetData.GetNewBlockChainFromClient(connection, @lastRequestId);
      // TODO: event
      if lastRequestId > 0 then
      begin
        while FNetData.RequestAlive(lastRequestId) do
        begin
          Sleep(100);
        end;
      end;

      FNetData.FMaxRemoteOperationBlock := CT_OperationBlock_NUL;

      InterLockedIncrement(FNetData.FBlockChainUpdateRequests);

      connection.RefDec;
    except
      On E:Exception do begin
        TLog.NewLog(lterror, ClassName, E.ClassName + ': ' + E.Message);
      end;
    end;
    candidates.Free;
  end;
end;

procedure TNetDataNotifyEventsThread.Execute;
begin
  while (not Terminated) do begin
    if (FNotifyOnReceivedHelloMessage) Or
       (FNotifyOnStatisticsChanged) Or
       (FNotifyOnNetConnectionsUpdated) Or
       (FNotifyOnNodeServersUpdated) Or
       (FNotifyOnBlackListUpdated) then begin
{$IFDEF CONSOLE}
      SynchronizedNotify;
{$ELSE}
      Synchronize(SynchronizedNotify);
{$ENDIF}
    end;
    Sleep(10);
  end;
end;

constructor TNetDataNotifyEventsThread.Create(ANetData: TNetData);
begin
  FNetData := ANetData;
  FNotifyOnReceivedHelloMessage := false;
  FNotifyOnStatisticsChanged := false;
  FNotifyOnNetConnectionsUpdated := false;
  FNotifyOnNodeServersUpdated := false;
  FNotifyOnBlackListUpdated := false;
  inherited Create(false);
end;

procedure TNetDataNotifyEventsThread.SynchronizedNotify;
begin
  if Terminated then exit;
  if Not Assigned(FNetData) then exit;

  if FNotifyOnReceivedHelloMessage then begin
    FNotifyOnReceivedHelloMessage := false;
    If Assigned(FNetData.FOnReceivedHelloMessage) then FNetData.FOnReceivedHelloMessage(FNetData);
  end;
  if FNotifyOnStatisticsChanged then begin
    FNotifyOnStatisticsChanged := false;
    If Assigned(FNetData.FOnStatisticsChanged) then FNetData.FOnStatisticsChanged(FNetData);
  end;
  if FNotifyOnNetConnectionsUpdated then begin
    FNotifyOnNetConnectionsUpdated := false;
    If Assigned(FNetData.FOnNetConnectionsUpdated) then FNetData.FOnNetConnectionsUpdated(FNetData);
  end;
  if FNotifyOnNodeServersUpdated then begin
    FNotifyOnNodeServersUpdated := false;
    If Assigned(FNetData.FOnNodeServersUpdated) then FNetData.FOnNodeServersUpdated(FNetData);
  end;
  if FNotifyOnBlackListUpdated then begin
    FNotifyOnBlackListUpdated := false;
    If Assigned(FNetData.FOnBlackListUpdated) then FNetData.FOnBlackListUpdated(FNetData);
  end;
end;

procedure TNetClientsDestroyThread.Execute;
Var l,l_to_del : TList;
  i : Integer;
begin
  l_to_del := TList.Create;
  Try
    while not Terminated do begin
      l_to_del.Clear;
      l := FNetData.ConnectionsLock;
      try
        FTerminatedAllConnections := l.Count=0;
        for i := 0 to l.Count-1 do begin
          If (TObject(l[i]) is TNetClient) And (not TNetConnection(l[i]).Connected) And (TNetConnection(l[i]).FDoFinalizeConnection) then begin
            l_to_del.Add(l[i]);
          end;
        end;
      finally
        FNetData.ConnectionsUnlock;
      end;

      for i := 0 to l_to_del.Count - 1 do begin
        if TNetConnection(l_to_del[i]).FRefCount <> 0 then
        begin
          Continue;
        end;
        If FNetData.ConnectionLock(Self, TNetConnection(l_to_del[i])) then begin
          try
            TNetConnection(l_to_del[i]).Free;
          finally
            // Not Necessary because on Freeing then Lock is deleted.
            // -> TNetData.NetData.ConnectionUnlock(FNetClient);
          end;
        end;
      end;
      Sleep(100);
    end;
  Finally
    l_to_del.Free;
  end;
end;

constructor TNetClientsDestroyThread.Create(NetData: TNetData);
begin
  FNetData:=NetData;
  FTerminatedAllConnections := true;
  Inherited Create(false);
end;

procedure TNetClientsDestroyThread.WaitForTerminatedAllConnections;
begin
  while (Not FTerminatedAllConnections) do begin
    TLog.NewLog(ltdebug,ClassName,'Waiting all connections terminated');
    Sleep(100);
  end;
end;

finalization
  FreeAndNil(_NetData);
end.
