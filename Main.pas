unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, IdBaseComponent, IdComponent,
  IdTCPConnection, IdTCPClient, IdHTTP, Vcl.Grids, Vcl.StdCtrls, Vcl.ExtCtrls,
  Clipbrd, System.NetEncoding,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent,
  Vcl.ComCtrls, System.ImageList, Vcl.ImgList, Vcl.Menus,
  System.Generics.Collections, System.IOUtils, Winapi.ShellAPI, System.IniFiles,
  System.Win.Registry, System.JSON, Vcl.Imaging.pngimage;

type
  TForm1 = class; // Предварительное объявление

  // Поток проверки TCP-соединения с привязкой к строке StringGrid
  TTCPCheckThread = class(TThread)
  private
    FForm: TForm1;
    FRowIndex: Integer;
    FIP: string;
    FPort: Integer;
    FStatus: string;
    procedure UpdateUI;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; ARowIndex: Integer; AIP: string; APort: Integer);
  end;

  // Фоновый поток для скачивания и парсинга серверов
  TUpdateThread = class(TThread)
  private
    FForm: TForm1;
    FErrorMessage: string;
    FSuccess: Boolean;
    FIsAuto: Boolean; // True — запущено таймером автообновления, а не нажатием «Обновить»
    FTempServers: TStringList;
    FTempOvpn: TDictionary<string, string>;
    procedure UpdateUI;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; AIsAuto: Boolean = False);
    destructor Destroy; override;
  end;

  TSoftEtherAction = (seaConnect, seaDisconnect);

  // Поток, который настраивает и подключает/отключает соединение SoftEther
  // через утилиту vpncmd.exe (управляет уже установленным SoftEther VPN
  // Client), не блокируя интерфейс — каждый вызов vpncmd — это отдельный
  // внешний процесс, который может занять секунду и больше.
  TSoftEtherThread = class(TThread)
  private
    FForm: TForm1;
    FAction: TSoftEtherAction;
    FServerIP: string;
    FServerPort: Integer;
    FStatusText: string;
    FConnectedIP: string; // IP сервера, который нужно (пере)отметить подключённым в таблице ('' — снять отметку)
    FAttemptId: Integer;  // номер этой попытки (см. TForm1.FSoftEtherAttemptId)
    function Superseded: Boolean;
    function RunCmd(const Args: string; out Output: string; LogOutput: Boolean = True): DWORD;
    procedure SyncStatus;
    procedure SyncConnectedIP;
    procedure SyncConnectFailed;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; AAction: TSoftEtherAction; const AServerIP: string; AServerPort: Integer);
  end;

  // Фоновая проверка активного SoftEther-подключения: спрашивает у vpncmd,
  // жива ли сессия (то же самое, что уже используется при установлении
  // соединения), и параллельно пингует сам сервер — только для отображения.
  // FGeneration — "поколение" подключения (см. TForm1.FConnectionGeneration):
  // если пользователь успел отключиться/переподключиться, пока эта проверка
  // выполнялась, её результат уже устарел и должен быть просто отброшен.
  TConnectionMonitorThread = class(TThread)
  private
    FForm: TForm1;
    FTargetIP: string;
    FGeneration: Integer;
    FSessionAlive: Boolean;
    FPingText: string;
    procedure SyncResult;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; const ATargetIP: string; AGeneration: Integer);
  end;

  // Проверяет последний релиз на GitHub (см. GitHubRepoOwner/GitHubRepoName)
  // и сравнивает его тег версии с AppVersion. Ничего не скачивает и не
  // подменяет сам исполняемый файл — только показывает ссылку на страницу
  // релиза, если версия там новее (самозамена запущенного .exe — отдельная,
  // куда более рискованная задача, тут сознательно не реализована).
  TAppUpdateCheckThread = class(TThread)
  private
    FForm: TForm1;
    FSilent: Boolean; // True — тихая проверка при запуске: ничего не сообщаем, если обновлений нет или сеть недоступна
    FSuccess: Boolean;
    FLatestVersion: string;
    FReleaseUrl: string;
    procedure SyncResult;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; ASilent: Boolean);
  end;

  // Скачивает готовое PNG-изображение QR-кода с внешнего сервиса
  // api.qrserver.com (никакой QR-кодировщик в саму программу не встраиваем —
  // это отдельный, довольно объёмный алгоритм, а тут кодируется всего
  // IP:Порт, пара десятков байт). QR специально не содержит сам .ovpn —
  // см. комментарий у TForm1.ShowServerQRCode.
  TQRCodeFetchThread = class(TThread)
  private
    FForm: TForm1;
    FQRText: string;
    FSuccess: Boolean;
    FImageBytes: TBytes;
    procedure SyncResult;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; const AQRText: string);
  end;

  TForm1 = class(TForm)
    Panel1: TPanel;
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
    ButtonInfo: TButton;
    StringGrid1: TStringGrid;
    NetHTTPClient1: TNetHTTPClient;
    ProgressBar1: TProgressBar;
    ImageList1: TImageList;
    StatusBar1: TStatusBar;
    PopupMenu1: TPopupMenu;
    MenuCopyIP: TMenuItem;
    MenuCopyPort: TMenuItem;
    MenuRecheckServer: TMenuItem;
    MenuSaveOvpn: TMenuItem;
    MenuConnectSoftEther: TMenuItem;
    MenuDisconnectSoftEther: TMenuItem;
    SaveDialog1: TSaveDialog;
    OpenDialog1: TOpenDialog;
    TrayIcon1: TTrayIcon;
    TrayPopupMenu: TPopupMenu;
    MenuTrayShow: TMenuItem;
    MenuTrayExit: TMenuItem;
    ButtonSettings: TButton;
    UpdateTimer: TTimer;
    LblCountry: TLabel;
    ComboCountry: TComboBox;
    ChkFavoritesOnly: TCheckBox;
    MenuToggleFavorite: TMenuItem;
    MenuShowQR: TMenuItem;
    PingTimer: TTimer;
    MenuTrayQuickConnect: TMenuItem;
    MenuTrayCheckUpdate: TMenuItem;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure ButtonInfoClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure NetHTTPClient1ValidateServerCertificate(const Sender: TObject;
      const ARequest: TURLRequest; const Certificate: TCertificate;
      var Accepted: Boolean);
    procedure StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer;
      Rect: TRect; State: TGridDrawState);
    procedure FormResize(Sender: TObject);
    procedure StringGrid1MouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure StringGrid1DblClick(Sender: TObject);
    procedure MenuCopyIPClick(Sender: TObject);
    procedure MenuCopyPortClick(Sender: TObject);
    procedure MenuRecheckServerClick(Sender: TObject);
    procedure MenuSaveOvpnClick(Sender: TObject);
    procedure MenuConnectSoftEtherClick(Sender: TObject);
    procedure MenuDisconnectSoftEtherClick(Sender: TObject);
    procedure TrayIcon1DblClick(Sender: TObject);
    procedure MenuTrayShowClick(Sender: TObject);
    procedure MenuTrayExitClick(Sender: TObject);
    procedure ButtonSettingsClick(Sender: TObject);
    procedure UpdateTimerTimer(Sender: TObject);
    procedure ComboCountryChange(Sender: TObject);
    procedure ChkFavoritesOnlyClick(Sender: TObject);
    procedure MenuToggleFavoriteClick(Sender: TObject);
    procedure MenuShowQRClick(Sender: TObject);
    procedure PingTimerTimer(Sender: TObject);
    procedure MenuTrayQuickConnectClick(Sender: TObject);
    procedure MenuTrayCheckUpdateClick(Sender: TObject);
  private
    FOvpnConfigs: TDictionary<string, string>; // IP -> декодированный .ovpn (заполняется при обновлении списка)
    FContextRow: Integer;                      // Строка, по которой кликнули правой кнопкой (для контекстного меню)
    FSortColumn: Integer;                      // Текущая колонка сортировки (-1 — нет)
    FSortAscending: Boolean;                   // Направление текущей сортировки
    FVpnCmdPath: string;                       // Путь к vpncmd.exe (SoftEther VPN Client), находится один раз
    FConnectedServerIP: string;                // IP сервера, к которому сейчас поднято SoftEther-подключение ('' — нет)
    FMasterList: TStringList;                  // Полный список серверов — единственный источник истины; таблица всегда перестраивается из него (см. RebuildGridFromMaster)
    FShowingWorkingOnly: Boolean;               // True — в таблице показаны только серверы со статусом «Работает!»
    FFilterCountry: string;                     // '' — все страны, иначе точное совпадение с колонкой «Страна»
    FFavoritesOnly: Boolean;                    // True — в таблице показаны только избранные серверы
    FFavorites: TStringList;                    // Множество IP избранных серверов (Sorted, без дублей)
    FAutoUpdateEnabled: Boolean;                // Включено ли автообновление списка серверов по таймеру
    FAutoUpdateMinutes: Integer;                // Интервал автообновления, в минутах
    FAutoReconnectEnabled: Boolean;             // Переподключаться ли автоматически к другому серверу при обрыве связи
    FConnectionGeneration: Integer;             // Увеличивается при каждом (пере)подключении/отключении — отсекает устаревшие результаты фоновых проверок
    FSoftEtherAttemptId: Integer;               // Номер последнего запущенного TSoftEtherThread — более старые потоки по нему понимают, что их попытка уже отменена
    FConsecutiveDrops: Integer;                 // Сколько подряд проверок связи подряд не прошли
    FReconnecting: Boolean;                     // True между обнаружением обрыва и стартом нового TSoftEtherThread — не даёт запустить переподключение дважды подряд
    FCascadeAttemptIPs: TStringList;            // IP серверов, уже испробованных в текущем каскаде подключения (nil — каскад не идёт)
    FCascadeRemaining: Integer;                 // Сколько ещё серверов можно попробовать в текущем каскаде
    procedure StartServerListUpdate(AIsAuto: Boolean);
    procedure LoadAutoUpdateSettings;
    procedure SaveAutoUpdateSettings;
    procedure ApplyAutoUpdateTimer;
    procedure ShowAutoUpdateSettingsDialog;
    procedure SaveListToFile;
    procedure UpdateStats;
    procedure UpdateSortHeaders;
    procedure SaveOvpnForRow(ARow: Integer);
    function LocateVpnCmd: string;
    procedure SetVpnStatusText(const S: string);
    procedure SetConnectedServerIP(const IP: string);
    function EnsureElevatedForSoftEther: Boolean;
    procedure ApplicationMinimize(Sender: TObject);
    procedure RestoreFromTray;
    procedure RebuildGridFromMaster;
    procedure ApplySort;
    procedure UpdateMasterStatus(const IP, NewStatus: string);
    procedure PopulateCountryCombo;
    procedure LoadFavorites;
    procedure SaveFavorites;
    function IsFavorite(const IP: string): Boolean;
    procedure ToggleFavorite(const IP: string);
    function FindBestServerRow(out IP: string; out Port: Integer; const ExcludeIP: string = '';
      ExcludeIPs: TStrings = nil): Boolean;
    procedure ConnectToServer(const IP: string; APort: Integer);
    procedure ReconnectToNextBestServer(const ExcludeIP: string);
    procedure HandleMonitorResult(SessionAlive: Boolean; const PingText: string);
    procedure StartCascadeConnect(const InitialExcludeIP: string);
    procedure TryNextCascadeCandidate;
    procedure HandleConnectAttemptFailed(const FailedIP: string);
    procedure ShowServerQRCode(const QRText: string; const ImageBytes: TBytes; Success: Boolean);
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

const
  // Базовые (без стрелки сортировки) подписи сортируемых колонок:
  // 1 - IP, 2 - Порт, 3 - Страна, 4 - Пинг (мс), 5 - Скорость (Мбит/с)
  ColHeaderBase: array[1..5] of string = ('IP', 'Порт', 'Страна', 'Пинг, мс', 'Скорость, Мбит/с');

  // Версия программы — при выпуске новой сборки менять вручную здесь и
  // одновременно создавать на GitHub релиз с тегом вида "v1.2.0" (см.
  // TAppUpdateCheckThread): у выложенного .exe и у тега должна быть одна
  // и та же версия, иначе проверка обновлений будет врать.
  AppVersion = '1.0.0';
  GitHubRepoOwner = 'babamurad';
  GitHubRepoName = 'MyVPNGate';

// Сравнение IP-адресов по числовым октетам, а не как обычных строк
// (иначе, например, "10.0.0.1" оказался бы "меньше" "9.0.0.1")
function CompareIP(const A, B: string): Integer;
var
  PartsA, PartsB: TArray<string>;
  i, VA, VB: Integer;
begin
  PartsA := A.Split(['.']);
  PartsB := B.Split(['.']);
  Result := 0;
  for i := 0 to 3 do
  begin
    if i < Length(PartsA) then VA := StrToIntDef(PartsA[i], 0) else VA := 0;
    if i < Length(PartsB) then VB := StrToIntDef(PartsB[i], 0) else VB := 0;
    if VA <> VB then
    begin
      Result := VA - VB;
      Exit;
    end;
  end;
end;

// Сравнение версий вида "1.2.0" (тег релиза GitHub может начинаться с "v" —
// её отбрасываем). Результат > 0, если A новее B; < 0 — если A старее.
function CompareVersions(const A, B: string): Integer;
var
  CleanA, CleanB: string;
  PartsA, PartsB: TArray<string>;
  i, VA, VB, PartCount: Integer;
begin
  CleanA := A;
  if (CleanA <> '') and CharInSet(CleanA[1], ['v', 'V']) then
    Delete(CleanA, 1, 1);
  CleanB := B;
  if (CleanB <> '') and CharInSet(CleanB[1], ['v', 'V']) then
    Delete(CleanB, 1, 1);

  PartsA := CleanA.Split(['.']);
  PartsB := CleanB.Split(['.']);
  Result := 0;

  PartCount := Length(PartsA);
  if Length(PartsB) > PartCount then PartCount := Length(PartsB);

  for i := 0 to PartCount - 1 do
  begin
    if i < Length(PartsA) then VA := StrToIntDef(PartsA[i], 0) else VA := 0;
    if i < Length(PartsB) then VB := StrToIntDef(PartsB[i], 0) else VB := 0;
    if VA <> VB then
    begin
      Result := VA - VB;
      Exit;
    end;
  end;
end;

// Достаёт число миллисекунд из вывода ping.exe — только для отображения
// (само определение "жив/не жив" опирается на код завершения ping.exe, а не
// на разбор текста). Понимает и английскую ("time=23ms"/"time<1ms"), и
// русскую ("время=23мс"/"время<1мс") локаль Windows; если формат не узнан —
// просто возвращает '-', не мешая остальной логике.
function ExtractPingMs(const Output: string): string;
var
  Lower: string;
  Pos1, Skip, Start, Len: Integer;
begin
  Result := '-';
  Lower := LowerCase(Output);

  Pos1 := Pos('time=', Lower);
  Skip := Length('time=');
  if Pos1 = 0 then
  begin
    Pos1 := Pos('время=', Lower);
    Skip := Length('время=');
  end;

  if Pos1 > 0 then
  begin
    Start := Pos1 + Skip;
    Len := 0;
    while (Start + Len <= Length(Lower)) and CharInSet(Lower[Start + Len], ['0'..'9']) do
      Inc(Len);
    if Len > 0 then
      Result := Copy(Output, Start, Len);
    Exit;
  end;

  if (Pos('time<', Lower) > 0) or (Pos('время<', Lower) > 0) then
    Result := '<1';
end;

const
  // Настройки автоматического подключения через SoftEther (публичные узлы
  // VPN Gate работают через фиксированный хаб и служебную пару логин/пароль)
  SoftEtherHubName = 'VPNGATE';
  SoftEtherUser = 'vpn';
  SoftEtherPassword = 'vpn';
  SoftEtherAccountName = 'MyVPNGateQuick'; // одно и то же имя переиспользуется под любой сервер
  SoftEtherNicName = 'VPN'; // имя виртуального адаптера по умолчанию у SoftEther VPN Client Manager
  VpnCmdPathCacheFile = 'vpncmd_path.txt';
  SoftEtherLogFile = 'softether_log.txt'; // журнал команд vpncmd при подключении (см. AppendSoftEtherLog)
  // Если рядом с программой лежит файл с этим именем — считаем его
  // официальным установщиком SoftEther VPN Client и предлагаем запустить
  // его сам, вместо того чтобы отправлять пользователя искать его в сети
  SoftEtherInstallerFile = 'SoftEtherClientSetup.exe';
  ServersUpdatedFile = 'servers_updated.txt'; // хранит дату/время последнего успешного обновления списка серверов
  AutoUpdateSettingsFile = 'autoupdate.ini';  // хранит настройки автообновления (включено/выключено, интервал)
  DefaultAutoUpdateMinutes = 30;
  MinAutoUpdateMinutes = 5;
  MaxAutoUpdateMinutes = 1440; // сутки
  FavoritesFile = 'favorites.txt';  // список избранных IP, по одному в строке
  AllCountriesLabel = 'Все страны'; // пункт "без фильтра" в ComboCountry
  AutoStartRegKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AutoStartValueName = 'MyVPNGate';

// Запускает внешний процесс, скрыто (без окна), и возвращает весь его
// стандартный вывод (stdout+stderr) одной строкой. Используется для вызова
// vpncmd.exe — своего готового аналога в VCL (наподобие TProcess) нет,
// поэтому напрямую через WinAPI (CreateProcess + анонимный pipe).
function RunProcessCapture(const CommandLine: string; TimeoutMs: Cardinal; out Output: string; out ExitCode: DWORD): Boolean;
var
  SecurityAttr: TSecurityAttributes;
  StdOutRead, StdOutWrite: THandle;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  CmdLine: string;
  WaitResult: DWORD;
begin
  Result := False;
  Output := '';
  ExitCode := DWORD(-1);
  StdOutWrite := 0;

  FillChar(SecurityAttr, SizeOf(SecurityAttr), 0);
  SecurityAttr.nLength := SizeOf(SecurityAttr);
  SecurityAttr.bInheritHandle := True;

  if not CreatePipe(StdOutRead, StdOutWrite, @SecurityAttr, 0) then Exit;
  try
    SetHandleInformation(StdOutRead, HANDLE_FLAG_INHERIT, 0);

    FillChar(StartupInfo, SizeOf(StartupInfo), 0);
    StartupInfo.cb := SizeOf(StartupInfo);
    StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    StartupInfo.wShowWindow := SW_HIDE;
    StartupInfo.hStdOutput := StdOutWrite;
    StartupInfo.hStdError := StdOutWrite;
    StartupInfo.hStdInput := 0;

    CmdLine := CommandLine;
    UniqueString(CmdLine); // CreateProcess требует изменяемый буфер

    if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
         CREATE_NO_WINDOW, nil, nil, StartupInfo, ProcessInfo) then
      Exit;

    CloseHandle(StdOutWrite);
    StdOutWrite := 0;

    repeat
      if not ReadFile(StdOutRead, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) or (BytesRead = 0) then
        Break;
      Buffer[BytesRead] := #0;
      Output := Output + string(AnsiString(PAnsiChar(@Buffer[0])));
    until False;

    WaitResult := WaitForSingleObject(ProcessInfo.hProcess, TimeoutMs);
    if WaitResult <> WAIT_OBJECT_0 then
      TerminateProcess(ProcessInfo.hProcess, 1);
    GetExitCodeProcess(ProcessInfo.hProcess, ExitCode);
    Result := True;

    CloseHandle(ProcessInfo.hProcess);
    CloseHandle(ProcessInfo.hThread);
  finally
    if StdOutWrite <> 0 then CloseHandle(StdOutWrite);
    CloseHandle(StdOutRead);
  end;
end;

// Вызывает "vpncmd.exe localhost /CLIENT /CMD <Args>" — управление локально
// установленным и уже запущенным SoftEther VPN Client.
//
// В Output возвращается ТОЛЬКО результат самой команды: vpncmd перед этим
// всегда печатает служебную шапку с версией и строкой
// 'Connected to VPN Client "localhost".' — она означает лишь то, что САМА
// утилита vpncmd подключилась к локальной службе, и никак не связана с
// состоянием VPN-сессии. Если её не отрезать, любой текстовый поиск слова
// "connected" (например, в AccountStatusGet) ложно сработает на эту шапку
// при любом вызове, вне зависимости от реального результата.
//
// ExitCode — код завершения самого vpncmd.exe: 0 при успехе команды, иначе
// код ошибки SoftEther. В отличие от текста ответа, он не зависит от языка
// интерфейса SoftEther, поэтому по нему надёжнее понять, что команда не
// выполнилась.
function RunVpnCmdEx(const VpnCmdExe, Args: string; out Output: string; out ExitCode: DWORD): Boolean;
var
  RawOutput: string;
  PromptPos: Integer;
const
  PromptMarker = 'VPN Client>';
begin
  Result := RunProcessCapture('"' + VpnCmdExe + '" localhost /CLIENT /CMD ' + Args, 15000, RawOutput, ExitCode);

  // "VPN Client>" — это приглашение, за которым vpncmd эхом печатает саму
  // команду, а после перевода строки уже идёт её реальный результат.
  // Отрезаем всё до конца этой строки, оставляя только результат.
  PromptPos := Pos(PromptMarker, RawOutput);
  if PromptPos > 0 then
  begin
    Output := Copy(RawOutput, PromptPos + Length(PromptMarker), MaxInt);
    PromptPos := Pos(#10, Output); // пропускаем остаток строки-эха самой команды
    if PromptPos > 0 then
      Output := Copy(Output, PromptPos + 1, MaxInt);
  end
  else
    Output := RawOutput;
end;

function RunVpnCmd(const VpnCmdExe, Args: string; out Output: string): Boolean;
var
  DummyExitCode: DWORD;
begin
  Result := RunVpnCmdEx(VpnCmdExe, Args, Output, DummyExitCode);
end;

// Журнал всех команд vpncmd при подключении и их ответов — рядом с
// программой, в softether_log.txt. Без него по одному статусу «не удалось
// подключиться» невозможно понять, на каком шаге и почему SoftEther отказал.
procedure AppendSoftEtherLog(const Text: string);
const
  MaxLogSize = 1024 * 1024; // чтобы журнал не рос бесконечно
var
  LogPath: string;
begin
  LogPath := ExtractFilePath(ParamStr(0)) + SoftEtherLogFile;
  try
    if FileExists(LogPath) and (TFile.GetSize(LogPath) > MaxLogSize) then
      TFile.Delete(LogPath);
    TFile.AppendAllText(LogPath,
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Text + sLineBreak, TEncoding.UTF8);
  except
    // журнал — только для диагностики, его сбой не должен мешать подключению
  end;
end;

// Сжимает ответ vpncmd в одну строку для статус-бара — обычно это
// "Error occurred. (Error code: N)" и строка с описанием ошибки
function CompactVpnCmdOutput(const Output: string): string;
const
  MaxLen = 200;
var
  Lines: TStringList;
  i: Integer;
  S: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for i := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[i]);
      if (S = '') or (Pos('The command completed', S) = 1) then Continue;
      if Result <> '' then Result := Result + ' ';
      Result := Result + S;
    end;
  finally
    Lines.Free;
  end;
  if Length(Result) > MaxLen then
    Result := Copy(Result, 1, MaxLen) + '...';
end;

// Значение строки "Session Status |..." из ответа AccountStatusGet (например,
// "Retrying" или "Connecting") — '' если такой строки нет
function ExtractSessionStatus(const Output: string): string;
var
  Lines: TStringList;
  i, BarPos: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Output;
    for i := 0 to Lines.Count - 1 do
    begin
      BarPos := Pos('|', Lines[i]);
      if (BarPos > 0) and (Pos('session status', LowerCase(Copy(Lines[i], 1, BarPos))) > 0) then
        Exit(Trim(Copy(Lines[i], BarPos + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

// Собирает файл настроек VPN-подключения SoftEther Client в его собственном
// текстовом формате (том же, что даёт "AccountExport") и импортирует его
// через AccountImport — так надёжнее, чем собирать аккаунт командами
// AccountSet/AccountCreate/AccountDetailSet: у них просто нет параметра для
// NoUdpAcceleration (в интерфейсе — галка "Disable NAT-T"), а без него, как
// выяснилось на практике, подключение к публичным узлам VPN Gate не
// проходит. Значения ниже (кроме Hostname/Port) списаны с реально рабочего,
// вручную настроенного подключения.
function BuildSoftEtherAccountFile(const IP: string; APort: Integer): string;
begin
  Result :=
    '# VPN Client VPN Connection Setting File' + sLineBreak +
    '# Сгенерировано MyVPNGate' + sLineBreak +
    sLineBreak +
    'declare root' + sLineBreak +
    '{' + sLineBreak +
    '        bool CheckServerCert false' + sLineBreak +
    '        uint64 CreateDateTime 0' + sLineBreak +
    '        uint64 LastConnectDateTime 0' + sLineBreak +
    '        bool StartupAccount false' + sLineBreak +
    '        uint64 UpdateDateTime 0' + sLineBreak +
    sLineBreak +
    '        declare ClientAuth' + sLineBreak +
    '        {' + sLineBreak +
    '                uint AuthType 1' + sLineBreak +
    '                byte HashedPassword H8N7rT8BH44q0nFXC9NlFxetGzQ=' + sLineBreak +
    '                string Username ' + SoftEtherUser + sLineBreak +
    '        }' + sLineBreak +
    '        declare ClientOption' + sLineBreak +
    '        {' + sLineBreak +
    '                string AccountName ' + SoftEtherAccountName + sLineBreak +
    '                uint AdditionalConnectionInterval 1' + sLineBreak +
    '                uint ConnectionDisconnectSpan 0' + sLineBreak +
    '                string DeviceName ' + SoftEtherNicName + sLineBreak +
    '                bool DisableQoS false' + sLineBreak +
    '                bool HalfConnection false' + sLineBreak +
    '                bool HideNicInfoWindow false' + sLineBreak +
    '                bool HideStatusWindow false' + sLineBreak +
    '                string Hostname ' + IP + '/tcp' + sLineBreak +
    '                string HubName ' + SoftEtherHubName + sLineBreak +
    '                uint MaxConnection 1' + sLineBreak +
    '                bool NoRoutingTracking false' + sLineBreak +
    '                bool NoTls1 false' + sLineBreak +
    '                bool NoUdpAcceleration false' + sLineBreak +
    '                uint NumRetry 4294967295' + sLineBreak +
    '                uint Port ' + IntToStr(APort) + sLineBreak +
    '                uint PortUDP 0' + sLineBreak +
    '                string ProxyName $' + sLineBreak +
    '                byte ProxyPassword $' + sLineBreak +
    '                uint ProxyPort 0' + sLineBreak +
    '                uint ProxyType 0' + sLineBreak +
    '                string ProxyUsername $' + sLineBreak +
    '                bool RequireBridgeRoutingMode false' + sLineBreak +
    '                bool RequireMonitorMode false' + sLineBreak +
    '                uint RetryInterval 15' + sLineBreak +
    '                bool UseCompress false' + sLineBreak +
    '                bool UseEncrypt true' + sLineBreak +
    '        }' + sLineBreak +
    '}' + sLineBreak;
end;

// Настройка VPN-подключения через vpncmd (даже к уже существующему аккаунту)
// требует повышенных прав — без них AccountCreate/AccountSet у SoftEther
// Client Service молча ничего не сохраняют. Проверяем реальную elevation
// текущего процесса через его токен доступа (а не просто членство в группе
// администраторов — оно не отражает, повышен ли токен сейчас).
function IsRunningElevated: Boolean;
var
  TokenHandle: THandle;
  Elevation: TTokenElevation;
  ReturnLength: DWORD;
begin
  Result := False;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, TokenHandle) then
  begin
    try
      if GetTokenInformation(TokenHandle, TokenElevation, @Elevation, SizeOf(Elevation), ReturnLength) then
        Result := Elevation.TokenIsElevated <> 0;
    finally
      CloseHandle(TokenHandle);
    end;
  end;
end;

// Перезапускает саму программу от имени администратора (через UAC-запрос
// "runas") и завершает текущий, неповышенный процесс. Если пользователь
// отменит запрос UAC, ShellExecuteEx вернёт False и ничего не произойдёт —
// текущий процесс продолжает работать как есть.
procedure RelaunchElevated;
var
  SEI: TShellExecuteInfo;
begin
  FillChar(SEI, SizeOf(SEI), 0);
  SEI.cbSize := SizeOf(SEI);
  SEI.fMask := SEE_MASK_DEFAULT;
  SEI.lpVerb := 'runas';
  SEI.lpFile := PChar(ParamStr(0));
  SEI.lpDirectory := PChar(ExtractFilePath(ParamStr(0)));
  SEI.nShow := SW_SHOWNORMAL;
  if ShellExecuteEx(@SEI) then
    Application.Terminate;
end;

// Автозапуск с Windows — обычный ключ Run в реестре текущего пользователя
// (не требует прав администратора, в отличие от HKLM). Сам факт наличия
// значения в реестре и есть текущее состояние настройки — отдельно на диске
// её не храним, чтобы не разъезжались два источника истины.
function IsAutoStartEnabled: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(AutoStartRegKey) then
      Result := Reg.ValueExists(AutoStartValueName);
  finally
    Reg.Free;
  end;
end;

procedure SetAutoStartEnabled(Enable: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(AutoStartRegKey, True) then
    begin
      if Enable then
        // /minimized — при запуске сразу прячемся в трей, а не открываем окно
        Reg.WriteString(AutoStartValueName, '"' + ParamStr(0) + '" /minimized')
      else if Reg.ValueExists(AutoStartValueName) then
        Reg.DeleteValue(AutoStartValueName);
    end;
  finally
    Reg.Free;
  end;
end;

{ TSoftEtherThread }

constructor TSoftEtherThread.Create(AForm: TForm1; AAction: TSoftEtherAction;
  const AServerIP: string; AServerPort: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FForm := AForm;
  FAction := AAction;
  FServerIP := AServerIP;
  FServerPort := AServerPort;
  // Конструктор вызывается из главного потока, так что счётчик меняется
  // только здесь, без гонок
  Inc(AForm.FSoftEtherAttemptId);
  FAttemptId := AForm.FSoftEtherAttemptId;
end;

// Запущена ли после этой попытки новая (подключение к другому серверу или
// отключение). Новая попытка первым делом делает AccountDisconnect, и без
// этой проверки старый поток видел в AccountStatusGet «not connected»
// (код 37) и сообщал ошибку уже про СВОЙ сервер — в статус-баре оказывалась
// чужая ошибка, а в каскаде ещё и запускался лишний шаг перебора.
function TSoftEtherThread.Superseded: Boolean;
begin
  Result := FAttemptId <> FForm.FSoftEtherAttemptId;
end;

procedure TSoftEtherThread.SyncStatus;
begin
  if Superseded then Exit;
  FForm.SetVpnStatusText(FStatusText);
end;

procedure TSoftEtherThread.SyncConnectedIP;
begin
  if Superseded then Exit;
  FForm.SetConnectedServerIP(FConnectedIP);
end;

procedure TSoftEtherThread.SyncConnectFailed;
begin
  if Superseded then Exit;
  FForm.SetVpnStatusText(FStatusText);
  FForm.HandleConnectAttemptFailed(FServerIP);
end;

// Выполняет команду vpncmd и пишет её вместе с ответом и кодом завершения в
// журнал (см. AppendSoftEtherLog). LogOutput = False — только для частого
// опроса статуса, чтобы журнал не забивался одинаковыми ответами.
function TSoftEtherThread.RunCmd(const Args: string; out Output: string; LogOutput: Boolean): DWORD;
begin
  if not RunVpnCmdEx(FForm.FVpnCmdPath, Args, Output, Result) then
  begin
    Result := DWORD(-1);
    AppendSoftEtherLog('> ' + Args + '  —  не удалось запустить vpncmd.exe (' + FForm.FVpnCmdPath + ')');
    Exit;
  end;
  if LogOutput then
    AppendSoftEtherLog('> ' + Args + '  [код ' + IntToStr(Integer(Result)) + ']' + sLineBreak + Trim(Output));
end;

procedure TSoftEtherThread.Execute;
var
  Output, LowerOutput, ConfigPath, LastStatusOutput, SessionStatus, ErrorText: string;
  Attempt: Integer;
  ExitCode: DWORD;
  Connected, Failed: Boolean;
begin
  if FForm.FVpnCmdPath = '' then
  begin
    FStatusText := 'VPN: vpncmd.exe не найден';
    Synchronize(SyncStatus);
    Exit;
  end;

  if FAction = seaDisconnect then
  begin
    FStatusText := 'VPN: отключение...';
    Synchronize(SyncStatus);
    AppendSoftEtherLog('=== Отключение ===');
    RunCmd('AccountDisconnect ' + SoftEtherAccountName, Output);
    FStatusText := 'VPN: отключено';
    Synchronize(SyncStatus);
    FConnectedIP := '';
    Synchronize(SyncConnectedIP);
    Exit;
  end;

  // seaConnect — прежняя сессия (если была) сейчас будет разорвана, снимаем
  // отметку с той строки сразу, не дожидаясь результата новой попытки
  FConnectedIP := '';
  Synchronize(SyncConnectedIP);

  FStatusText := 'VPN: настройка подключения к ' + FServerIP + '...';
  Synchronize(SyncStatus);

  AppendSoftEtherLog('=== Подключение к ' + FServerIP + ':' + IntToStr(FServerPort) + ' ===');

  // На случай, если уже была активна предыдущая попытка/сессия
  RunCmd('AccountDisconnect ' + SoftEtherAccountName, Output);

  // Всегда пересоздаём аккаунт заново через импорт файла настроек (а не
  // AccountSet/AccountCreate) — так гарантированно выставляются ВСЕ нужные
  // параметры, включая NoUdpAcceleration (см. BuildSoftEtherAccountFile).
  // Сначала удаляем прежнюю версию — если её не было, ошибка безвредна.
  RunCmd('AccountDelete ' + SoftEtherAccountName, Output);
  if Superseded then Exit;

  ConfigPath := ExtractFilePath(ParamStr(0)) + 'softether_account.vpn';
  try
    TFile.WriteAllText(ConfigPath, BuildSoftEtherAccountFile(FServerIP, FServerPort), TEncoding.ASCII);
  except
    on E: Exception do
    begin
      FStatusText := 'VPN: не удалось подготовить файл настроек (' + E.Message + ')';
      AppendSoftEtherLog(FStatusText);
      Synchronize(SyncStatus);
      Exit;
    end;
  end;

  // Раньше результаты этих команд никак не проверялись: если, например,
  // импорт не прошёл, программа всё равно минуту ждала подключения и
  // сообщала лишь «не удалось подключиться» — без единого намёка на причину.
  // Теперь при ошибке любого шага сразу показываем ответ самого SoftEther.
  // Такая ошибка — не проблема конкретного сервера (она повторится на любом),
  // поэтому каскад перебора серверов на ней не продолжаем (SyncStatus, а не
  // SyncConnectFailed).
  ExitCode := RunCmd('AccountImport "' + ConfigPath + '"', Output);
  if Superseded then Exit;
  if ExitCode <> 0 then
  begin
    FStatusText := 'VPN: SoftEther не принял настройки подключения: ' + CompactVpnCmdOutput(Output);
    Synchronize(SyncStatus);
    Exit;
  end;

  // Пароль в файле — не настоящий (плейсхолдер-хэш из шаблона), выставляем
  // реальный отдельной командой, как и раньше
  RunCmd(Format('AccountPasswordSet %s /PASSWORD:%s /TYPE:standard',
    [SoftEtherAccountName, SoftEtherPassword]), Output);
  if Superseded then Exit;

  ExitCode := RunCmd('AccountConnect ' + SoftEtherAccountName, Output);
  if Superseded then Exit;
  if ExitCode <> 0 then
  begin
    FStatusText := 'VPN: SoftEther не запустил подключение: ' + CompactVpnCmdOutput(Output);
    Synchronize(SyncStatus);
    Exit;
  end;

  FStatusText := 'VPN: подключение к ' + FServerIP + '...';
  Synchronize(SyncStatus);

  Connected := False;
  Failed := False;
  ErrorText := '';
  SessionStatus := '';
  LastStatusOutput := '';
  // Ждём подключения до ~60 секунд: на практике SoftEther иногда успевает
  // подключиться уже ПОСЛЕ того, как здесь заканчивалось время ожидания
  // (20с оказалось мало — Client Manager показывал Connected, а мы уже
  // сообщали таймаут)
  for Attempt := 1 to 60 do
  begin
    Sleep(1000);
    if Superseded then
    begin
      AppendSoftEtherLog('Попытка подключения к ' + FServerIP + ' прервана новой попыткой');
      Exit;
    end;
    ExitCode := RunCmd('AccountStatusGet ' + SoftEtherAccountName, Output, False);
    if Superseded then Exit; // ответ мог относиться уже к новой попытке
    // В журнал — только когда ответ изменился, а не 60 одинаковых копий
    if Output <> LastStatusOutput then
    begin
      AppendSoftEtherLog('> AccountStatusGet ' + SoftEtherAccountName + '  [код ' +
        IntToStr(Integer(ExitCode)) + ', ' + IntToStr(Attempt) + ' с]' + sLineBreak + Trim(Output));
      LastStatusOutput := Output;
    end;
    LowerOutput := LowerCase(Output);
    if (ExtractSessionStatus(Output) <> '') and (ExtractSessionStatus(Output) <> SessionStatus) then
    begin
      SessionStatus := ExtractSessionStatus(Output);
      // Показываем живой статус SoftEther: "Retrying" уже через секунду —
      // значит, первое же соединение с сервером не удалось, и SoftEther
      // пробует снова (раз в RetryInterval секунд)
      FStatusText := 'VPN: подключение к ' + FServerIP + '... (SoftEther: ' + SessionStatus + ')';
      Synchronize(SyncStatus);
    end;

    // Реальный текст успешного статуса (проверено по живому выводу
    // AccountStatusGet) — не "Connected", а:
    //   Session Status |Connection Completed (Session Established)
    // Проверка на голое "connected" тут в принципе не могла сработать —
    // "Connection" и "Connected" разные слова, подстрока не совпадает.
    if (Pos('connection completed', LowerOutput) > 0) or
       (Pos('session established', LowerOutput) > 0) then
    begin
      Connected := True;
      Break;
    end;

    if (ExitCode <> 0) or (Pos('error occurred', LowerOutput) > 0) or
       (Pos('connection failed', LowerOutput) > 0) then
    begin
      Failed := True;
      ErrorText := CompactVpnCmdOutput(Output);
      Break;
    end;
  end;

  if Connected then
  begin
    FStatusText := 'VPN: подключено к ' + FServerIP;
    AppendSoftEtherLog(FStatusText);
    FConnectedIP := FServerIP;
    Synchronize(SyncConnectedIP);
    Synchronize(SyncStatus);
  end
  else
  begin
    if Failed then
      FStatusText := 'VPN: ошибка подключения к ' + FServerIP + ': ' + ErrorText
    else
    begin
      FStatusText := 'VPN: не удалось подключиться к ' + FServerIP + ' за отведённое время';
      if SessionStatus <> '' then
        FStatusText := FStatusText + ' (статус SoftEther: ' + SessionStatus + ')';
      // Иначе SoftEther продолжит бесконечно переподключаться к этому
      // серверу в фоне (NumRetry в настройках — без ограничения)
      RunCmd('AccountDisconnect ' + SoftEtherAccountName, Output);
    end;
    AppendSoftEtherLog(FStatusText);
    // Сообщаем форме именно о НЕУДАЧЕ этой попытки (в отличие от текста
    // статуса, который просто отображается) — если подключение шло через
    // каскад (см. TForm1.StartCascadeConnect), форма сама попробует
    // следующий по списку сервер вместо того, чтобы просто сдаться на
    // первом же "протухшем" узле.
    Synchronize(SyncConnectFailed);
  end;
end;

{ TConnectionMonitorThread }

constructor TConnectionMonitorThread.Create(AForm: TForm1; const ATargetIP: string; AGeneration: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FForm := AForm;
  FTargetIP := ATargetIP;
  FGeneration := AGeneration;
end;

procedure TConnectionMonitorThread.SyncResult;
begin
  // Пока проверка шла в фоне, могли успеть отключиться/переподключиться —
  // тогда это уже не то соединение, к которому относится результат
  if FGeneration <> FForm.FConnectionGeneration then Exit;
  FForm.HandleMonitorResult(FSessionAlive, FPingText);
end;

procedure TConnectionMonitorThread.Execute;
var
  Output, LowerOutput, PingOutput: string;
  ExitCode: DWORD;
begin
  // Жива ли сама SoftEther-сессия — тот же признак, что и при установлении
  // соединения (см. TSoftEtherThread.Execute): "Connection Completed" /
  // "Session Established", а не буквальное "Connected"
  FSessionAlive := False;
  if FForm.FVpnCmdPath <> '' then
  begin
    RunVpnCmd(FForm.FVpnCmdPath, 'AccountStatusGet ' + SoftEtherAccountName, Output);
    LowerOutput := LowerCase(Output);
    FSessionAlive := (Pos('connection completed', LowerOutput) > 0) or
                      (Pos('session established', LowerOutput) > 0);
  end;

  // Пинг сервера — только для отображения (см. ExtractPingMs); статус сессии
  // выше остаётся единственным, что решает, жива связь или нет
  RunProcessCapture('ping -n 1 -w 1500 ' + FTargetIP, 3000, PingOutput, ExitCode);
  if ExitCode = 0 then
    FPingText := ExtractPingMs(PingOutput)
  else
    FPingText := '-';

  Synchronize(SyncResult);
end;

{ TAppUpdateCheckThread }

constructor TAppUpdateCheckThread.Create(AForm: TForm1; ASilent: Boolean);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FForm := AForm;
  FSilent := ASilent;
end;

procedure TAppUpdateCheckThread.SyncResult;
begin
  if not FSuccess then
  begin
    if not FSilent then
      ShowMessage('Не удалось проверить обновления программы. Проверьте подключение к интернету.');
    Exit;
  end;

  if CompareVersions(FLatestVersion, AppVersion) > 0 then
  begin
    if MessageDlg('Доступна новая версия программы: ' + FLatestVersion +
         ' (у вас установлена ' + AppVersion + ').' + sLineBreak + sLineBreak +
         'Открыть страницу загрузки на GitHub?',
         mtInformation, [mbYes, mbNo], 0) = mrYes then
      ShellExecute(0, 'open', PChar(FReleaseUrl), nil, nil, SW_SHOWNORMAL);
  end
  else if not FSilent then
    ShowMessage('У вас установлена последняя версия программы (' + AppVersion + ').');
end;

procedure TAppUpdateCheckThread.Execute;
var
  Client: TNetHTTPClient;
  Response: string;
  JSONValue: TJSONValue;
begin
  FSuccess := False;
  Client := TNetHTTPClient.Create(nil);
  try
    try
      // GitHub API требует непустой User-Agent, иначе отвечает 403
      Client.UserAgent := 'MyVPNGate-UpdateCheck';
      Response := Client.Get('https://api.github.com/repos/' + GitHubRepoOwner +
        '/' + GitHubRepoName + '/releases/latest').ContentAsString();

      JSONValue := TJSONObject.ParseJSONValue(Response);
      if Assigned(JSONValue) then
      try
        if JSONValue is TJSONObject then
        begin
          FLatestVersion := TJSONObject(JSONValue).GetValue<string>('tag_name', '');
          FReleaseUrl := TJSONObject(JSONValue).GetValue<string>('html_url', '');
          FSuccess := (FLatestVersion <> '') and (FReleaseUrl <> '');
        end;
      finally
        JSONValue.Free;
      end;
    except
      // Нет сети, репозиторий недоступен, релизов ещё нет и т.п. — тихо
      // считаем, что проверить не удалось, ничего не роняем
      FSuccess := False;
    end;
  finally
    Client.Free;
  end;

  Synchronize(SyncResult);
end;

{ TQRCodeFetchThread }

constructor TQRCodeFetchThread.Create(AForm: TForm1; const AQRText: string);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FForm := AForm;
  FQRText := AQRText;
end;

procedure TQRCodeFetchThread.SyncResult;
begin
  FForm.ShowServerQRCode(FQRText, FImageBytes, FSuccess);
end;

procedure TQRCodeFetchThread.Execute;
var
  Client: TNetHTTPClient;
  Response: IHTTPResponse;
  Url: string;
  MS: TMemoryStream;
begin
  FSuccess := False;
  Client := TNetHTTPClient.Create(nil);
  try
    try
      Url := 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=' +
        TNetEncoding.URL.Encode(FQRText);
      Response := Client.Get(Url);
      if (Response.StatusCode = 200) and Assigned(Response.ContentStream) then
      begin
        // Через ContentStream, а не готовый ContentAsBytes — так надёжнее:
        // это самый базовый способ добраться до тела ответа, доступный
        // независимо от версии Delphi.
        MS := TMemoryStream.Create;
        try
          Response.ContentStream.Position := 0;
          MS.CopyFrom(Response.ContentStream, 0);
          SetLength(FImageBytes, MS.Size);
          if MS.Size > 0 then
            Move(MS.Memory^, FImageBytes[0], MS.Size);
          FSuccess := MS.Size > 0;
        finally
          MS.Free;
        end;
      end;
    except
      // Нет сети, сервис недоступен и т.п. — тихо считаем, что не получилось
      FSuccess := False;
    end;
  finally
    Client.Free;
  end;

  Synchronize(SyncResult);
end;

{ TTCPCheckThread }

constructor TTCPCheckThread.Create(AForm: TForm1; ARowIndex: Integer; AIP: string; APort: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := True;
  FForm := AForm;
  FRowIndex := ARowIndex;
  FIP := AIP;
  FPort := APort;
end;

procedure TTCPCheckThread.UpdateUI;
var
  R: Integer;
begin
  // В FMasterList результат нужно сохранить всегда — иначе он потеряется
  // при следующей перестройке таблицы (например, при смене фильтра)
  FForm.UpdateMasterStatus(FIP, FStatus);

  // Ищем строку в таблице по IP, а не по захваченному раньше FRowIndex — тот
  // мог "уехать", пока проверка шла в фоне (сортировка, смена фильтра)
  for R := 1 to FForm.StringGrid1.RowCount - 1 do
    if Trim(FForm.StringGrid1.Cells[1, R]) = FIP then
    begin
      FForm.StringGrid1.Cells[7, R] := FStatus;
      Break;
    end;
end;

procedure TTCPCheckThread.Execute;
var
  TCPClient: TIdTCPClient;
begin
  TCPClient := TIdTCPClient.Create(nil);
  try
    TCPClient.Host := FIP;
    TCPClient.Port := FPort;
    TCPClient.ConnectTimeout := 2000;
    TCPClient.ReadTimeout := 2000;
    try
      TCPClient.Connect;
      FStatus := 'Работает!';
    except
      FStatus := 'Недоступен';
    end;
    try
      if TCPClient.Connected then
        TCPClient.Disconnect;
    except
    end;
  finally
    try
      TCPClient.Free;
    except
      // Известная особенность Indy: после неудачного Connect деструктор
      // TIdTCPClient может сам попытаться разорвать соединение и упасть с
      // EIdNotASocket ("Socket Error #10038 Socket operation on non-socket").
      // Память объекта при этом всё равно освобождается штатно, поэтому
      // просто гасим исключение, чтобы оно не «вылетало» из потока.
    end;
  end;
  Synchronize(UpdateUI);
end;

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
var
  SL, Columns: TStringList;
  i: Integer;
  FilePath: string;
begin
  StringGrid1.ColCount := 8;
  StringGrid1.FixedRows := 1;
  StringGrid1.RowCount := 2;

  // Сворачивание в трей: значок в трее появляется при сворачивании окна и
  // прячется обратно при восстановлении (см. ApplicationMinimize/RestoreFromTray)
  TrayIcon1.Icon := Application.Icon;
  TrayIcon1.Hint := 'MyVPNGate';
  Application.OnMinimize := ApplicationMinimize;

  // Автообновление списка серверов по таймеру — настройки читаются с диска
  // и сразу применяются к таймеру (кнопка «Настройки» меняет их на лету)
  LoadAutoUpdateSettings;
  ApplyAutoUpdateTimer;

  FOvpnConfigs := TDictionary<string, string>.Create;
  FContextRow := -1;
  FSortColumn := -1;
  FSortAscending := True;
  FVpnCmdPath := ''; // находим лениво, при первом обращении к SoftEther
  FMasterList := TStringList.Create;
  FShowingWorkingOnly := False;
  FFilterCountry := '';
  FFavoritesOnly := False;
  FConnectedServerIP := '';
  FConnectionGeneration := 0;
  FConsecutiveDrops := 0;
  FCascadeAttemptIPs := nil;
  FCascadeRemaining := 0;

  LoadFavorites;

  // Заголовки колонок
  StringGrid1.Cells[0, 0] := '№';
  UpdateSortHeaders; // задаёт IP/Порт/Страна/Пинг/Скорость (колонки 1-5, сортируемые кликом по шапке)
  StringGrid1.Cells[6, 0] := 'Протокол';
  StringGrid1.Cells[7, 0] := 'Статус';

  // Ширина колонок
  StringGrid1.ColWidths[0] := 40;
  StringGrid1.ColWidths[1] := 130;
  StringGrid1.ColWidths[2] := 60;
  StringGrid1.ColWidths[3] := 100;
  StringGrid1.ColWidths[4] := 85;
  StringGrid1.ColWidths[5] := 130;
  StringGrid1.ColWidths[6] := 80;
  StringGrid1.ColWidths[7] := 150;

  StringGrid1.DoubleBuffered := True;
  StringGrid1.Options := StringGrid1.Options + [goRowSelect];
  StringGrid1.Options := StringGrid1.Options - [goEditing];
  // PopupMenu1 намеренно НЕ назначается через StringGrid1.PopupMenu — меню
  // показывается вручную из StringGrid1MouseDown (см. там), чтобы не зависеть
  // от WM_CONTEXTMENU/OnContextPopup и не показать его дважды.

  SaveDialog1.DefaultExt := 'ovpn';
  SaveDialog1.Filter := 'Конфигурация OpenVPN (*.ovpn)|*.ovpn|Все файлы (*.*)|*.*';

  OpenDialog1.Filter := 'vpncmd.exe|vpncmd.exe|Все файлы (*.*)|*.*';
  OpenDialog1.Title := 'Укажите путь к vpncmd.exe (SoftEther VPN Client)';

  // Дата/время последнего успешного обновления списка серверов — сохраняется
  // отдельным файлом, потому что servers.txt на диске может быть старым
  // (загружен в прошлый раз), и без этой отметки не видно, насколько
  // актуален список
  if StatusBar1.Panels.Count > 3 then
  try
    if FileExists(ExtractFilePath(ParamStr(0)) + ServersUpdatedFile) then
      StatusBar1.Panels[3].Text := 'Обновлено: ' +
        Trim(TFile.ReadAllText(ExtractFilePath(ParamStr(0)) + ServersUpdatedFile))
    else
      StatusBar1.Panels[3].Text := 'Обновлено: —';
  except
    StatusBar1.Panels[3].Text := 'Обновлено: —';
  end;

  // Всё содержимое servers.txt читается прямо в FMasterList (тот же формат
  // из 7 полей, что и внутри самого списка) — сама таблица заполняется уже
  // из него через RebuildGridFromMaster, с учётом текущих фильтров/сортировки
  FilePath := ExtractFilePath(ParamStr(0)) + 'servers.txt';
  if FileExists(FilePath) then
  begin
    SL := TStringList.Create;
    Columns := TStringList.Create;
    Columns.StrictDelimiter := True;
    Columns.Delimiter := ',';
    try
      SL.LoadFromFile(FilePath);
      for i := 0 to SL.Count - 1 do
      begin
        if Trim(SL[i]) = '' then Continue;
        Columns.DelimitedText := SL[i];
        if Columns.Count >= 7 then
          FMasterList.Add(SL[i]);
      end;
    finally
      SL.Free;
      Columns.Free;
    end;
  end;

  PopulateCountryCombo;
  RebuildGridFromMaster; // сама вызывает UpdateSortHeaders/UpdateStats

  // Запуск по автозагрузке Windows (см. SetAutoStartEnabled) сразу сворачивает
  // окно в трей, не показывая его на экране
  if FindCmdLineSwitch('minimized') then
  begin
    Hide;
    TrayIcon1.Visible := True;
  end;

  // Тихая проверка обновлений самой программы — ничего не покажет, если
  // обновлений нет или сеть недоступна (см. TAppUpdateCheckThread); вручную
  // её же можно вызвать пунктом «Проверить обновления программы» в трее
  TAppUpdateCheckThread.Create(Self, True);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FOvpnConfigs.Free;
  FMasterList.Free;
  FFavorites.Free;
  FCascadeAttemptIPs.Free;
end;

// Application.OnMinimize срабатывает при сворачивании главного окна —
// прячем его с панели задач и показываем значок в трее вместо него
procedure TForm1.ApplicationMinimize(Sender: TObject);
begin
  Hide;
  TrayIcon1.Visible := True;
end;

// Возвращает окно из трея обратно на экран (по двойному клику на значке
// или пункту «Показать» его контекстного меню)
procedure TForm1.RestoreFromTray;
begin
  TrayIcon1.Visible := False;
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
end;

procedure TForm1.TrayIcon1DblClick(Sender: TObject);
begin
  RestoreFromTray;
end;

procedure TForm1.MenuTrayShowClick(Sender: TObject);
begin
  RestoreFromTray;
end;

procedure TForm1.MenuTrayExitClick(Sender: TObject);
begin
  Close;
end;

procedure TForm1.FormResize(Sender: TObject);
var
  TotalWidth: Integer;
begin
  if Assigned(StringGrid1) and (StringGrid1.ColCount = 8) then
  begin
    TotalWidth := StringGrid1.ClientWidth - StringGrid1.ColWidths[0] -
                  StringGrid1.ColWidths[1] - StringGrid1.ColWidths[2] -
                  StringGrid1.ColWidths[3] - StringGrid1.ColWidths[4] -
                  StringGrid1.ColWidths[5] - StringGrid1.ColWidths[6] - 20;
    if TotalWidth > 150 then
      StringGrid1.ColWidths[7] := TotalWidth;
  end;
end;

procedure TForm1.Button1Click(Sender: TObject);
begin
  StartServerListUpdate(False);
end;

// Общий запуск фоновой загрузки списка — как по нажатию «Обновить» вручную,
// так и по таймеру автообновления (AIsAuto = True)
procedure TForm1.StartServerListUpdate(AIsAuto: Boolean);
begin
  // Сброс фильтра «Оставить только рабочие» откладываем до момента, когда
  // список действительно успешно загрузится (см. TUpdateThread.UpdateUI) —
  // если здесь сбросить его заранее, а загрузка не удастся (нет сети и т.п.),
  // отложенный фильтром полный список будет потерян, а в таблице так и
  // останутся только отфильтрованные строки, как будто остальные исчезли.

  // Прячем кнопку, чтобы исключить повторные нажатия
  Button1.Visible := False;

  // Показываем прогресс-бар ровно на месте кнопки
  ProgressBar1.Left := Button1.Left;
  ProgressBar1.Top := Button1.Top;
  ProgressBar1.Width := Button1.Width;
  ProgressBar1.Height := Button1.Height;
  ProgressBar1.Visible := True;

  // Запускаем фоновую загрузку
  TUpdateThread.Create(Self, AIsAuto);
end;

// Срабатывает по таймеру автообновления (интервал задаётся в «Настройках»)
procedure TForm1.UpdateTimerTimer(Sender: TObject);
begin
  // Если обновление уже идёт (например, только что нажали «Обновить»
  // вручную) — пропускаем это срабатывание, следующее будет через интервал
  if not Button1.Visible then Exit;
  StartServerListUpdate(True);
end;

// Читает настройки автообновления из autoupdate.ini рядом с исполняемым
// файлом; если файла ещё нет (первый запуск) — используются значения по
// умолчанию (автообновление выключено)
procedure TForm1.LoadAutoUpdateSettings;
var
  Ini: TIniFile;
begin
  FAutoUpdateEnabled := False;
  FAutoUpdateMinutes := DefaultAutoUpdateMinutes;
  FAutoReconnectEnabled := False;
  try
    Ini := TIniFile.Create(ExtractFilePath(ParamStr(0)) + AutoUpdateSettingsFile);
    try
      FAutoUpdateEnabled := Ini.ReadBool('AutoUpdate', 'Enabled', False);
      FAutoUpdateMinutes := Ini.ReadInteger('AutoUpdate', 'Minutes', DefaultAutoUpdateMinutes);
      FAutoReconnectEnabled := Ini.ReadBool('Connection', 'AutoReconnect', False);
    finally
      Ini.Free;
    end;
  except
    // Файла может не быть или он повреждён — остаёмся со значениями по умолчанию
  end;

  if FAutoUpdateMinutes < MinAutoUpdateMinutes then FAutoUpdateMinutes := MinAutoUpdateMinutes;
  if FAutoUpdateMinutes > MaxAutoUpdateMinutes then FAutoUpdateMinutes := MaxAutoUpdateMinutes;
end;

procedure TForm1.SaveAutoUpdateSettings;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(ExtractFilePath(ParamStr(0)) + AutoUpdateSettingsFile);
    try
      Ini.WriteBool('AutoUpdate', 'Enabled', FAutoUpdateEnabled);
      Ini.WriteInteger('AutoUpdate', 'Minutes', FAutoUpdateMinutes);
      Ini.WriteBool('Connection', 'AutoReconnect', FAutoReconnectEnabled);
    finally
      Ini.Free;
    end;
  except
    // Не критично, если не удалось сохранить настройки на диск
  end;
end;

// Применяет FAutoUpdateEnabled/FAutoUpdateMinutes к самому таймеру
procedure TForm1.ApplyAutoUpdateTimer;
begin
  UpdateTimer.Interval := FAutoUpdateMinutes * 60000;
  UpdateTimer.Enabled := FAutoUpdateEnabled;
end;

// Небольшой модальный диалог настроек — собирается прямо в коде, без
// отдельной формы, чтобы не плодить лишние файлы .pas/.dfm ради двух полей
procedure TForm1.ShowAutoUpdateSettingsDialog;
var
  Dlg: TForm;
  ChkEnabled, ChkAutoStart, ChkAutoReconnect: TCheckBox;
  LblMinutes: TLabel;
  EditMinutes: TEdit;
  BtnOK, BtnCancel: TButton;
  Minutes: Integer;
begin
  Dlg := TForm.Create(Self);
  try
    Dlg.Caption := 'Настройки';
    Dlg.BorderStyle := bsDialog;
    Dlg.Position := poOwnerFormCenter;
    Dlg.Font := Self.Font;
    Dlg.ClientWidth := 360;
    Dlg.ClientHeight := 222;

    ChkEnabled := TCheckBox.Create(Dlg);
    ChkEnabled.Parent := Dlg;
    ChkEnabled.SetBounds(16, 16, 320, 20);
    ChkEnabled.Caption := 'Автоматически обновлять список серверов';
    ChkEnabled.Checked := FAutoUpdateEnabled;

    LblMinutes := TLabel.Create(Dlg);
    LblMinutes.Parent := Dlg;
    LblMinutes.SetBounds(16, 52, 320, 16);
    LblMinutes.Caption := Format('Интервал, минут (от %d до %d):',
      [MinAutoUpdateMinutes, MaxAutoUpdateMinutes]);

    EditMinutes := TEdit.Create(Dlg);
    EditMinutes.Parent := Dlg;
    EditMinutes.SetBounds(16, 72, 80, 23);
    EditMinutes.NumbersOnly := True;
    EditMinutes.MaxLength := 5;
    EditMinutes.Text := IntToStr(FAutoUpdateMinutes);

    ChkAutoStart := TCheckBox.Create(Dlg);
    ChkAutoStart.Parent := Dlg;
    ChkAutoStart.SetBounds(16, 108, 320, 20);
    ChkAutoStart.Caption := 'Запускать вместе с Windows (свёрнуто в трей)';
    ChkAutoStart.Checked := IsAutoStartEnabled;

    ChkAutoReconnect := TCheckBox.Create(Dlg);
    ChkAutoReconnect.Parent := Dlg;
    ChkAutoReconnect.SetBounds(16, 144, 320, 20);
    ChkAutoReconnect.Caption := 'Переподключаться к другому серверу при обрыве связи';
    ChkAutoReconnect.Checked := FAutoReconnectEnabled;

    BtnOK := TButton.Create(Dlg);
    BtnOK.Parent := Dlg;
    BtnOK.Caption := 'ОК';
    BtnOK.ModalResult := mrOk;
    BtnOK.Default := True;
    BtnOK.SetBounds(Dlg.ClientWidth - 176, Dlg.ClientHeight - 40, 80, 28);

    BtnCancel := TButton.Create(Dlg);
    BtnCancel.Parent := Dlg;
    BtnCancel.Caption := 'Отмена';
    BtnCancel.ModalResult := mrCancel;
    BtnCancel.Cancel := True;
    BtnCancel.SetBounds(Dlg.ClientWidth - 88, Dlg.ClientHeight - 40, 72, 28);

    Dlg.ActiveControl := ChkEnabled;

    if Dlg.ShowModal = mrOk then
    begin
      Minutes := StrToIntDef(Trim(EditMinutes.Text), FAutoUpdateMinutes);
      if Minutes < MinAutoUpdateMinutes then Minutes := MinAutoUpdateMinutes;
      if Minutes > MaxAutoUpdateMinutes then Minutes := MaxAutoUpdateMinutes;

      FAutoUpdateEnabled := ChkEnabled.Checked;
      FAutoUpdateMinutes := Minutes;
      FAutoReconnectEnabled := ChkAutoReconnect.Checked;
      SaveAutoUpdateSettings;
      ApplyAutoUpdateTimer;

      SetAutoStartEnabled(ChkAutoStart.Checked);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.ButtonSettingsClick(Sender: TObject);
begin
  ShowAutoUpdateSettingsDialog;
end;

procedure TForm1.Button2Click(Sender: TObject);
var
  i: Integer;
begin
  for i := 1 to StringGrid1.RowCount - 1 do
  begin
    if Trim(StringGrid1.Cells[1, i]) <> '' then
    begin
      StringGrid1.Cells[7, i] := 'Проверка...';
      TTCPCheckThread.Create(Self, i, StringGrid1.Cells[1, i], StrToIntDef(StringGrid1.Cells[2, i], 443));
    end;
  end;
end;

// «Оставить только рабочие» — просто переключатель одного из фильтров;
// сама перерисовка (и то, что скрытые серверы не теряются, а лишь не
// показываются) обеспечивается тем, что RebuildGridFromMaster всегда
// строит таблицу заново из FMasterList, который этот фильтр не трогает.
procedure TForm1.Button3Click(Sender: TObject);
begin
  FShowingWorkingOnly := not FShowingWorkingOnly;
  if FShowingWorkingOnly then
    Button3.Caption := 'Показать все серверы'
  else
    Button3.Caption := 'Оставить только рабочие';
  RebuildGridFromMaster;
end;

// Перестраивает StringGrid1 из FMasterList — единственное место, где
// таблица заполняется данными. Применяет все активные фильтры (только
// рабочие / страна / только избранное) и сохраняет текущую сортировку.
procedure TForm1.RebuildGridFromMaster;
var
  i, RIdx: Integer;
  Cols: TArray<string>;
  IP, Status, Country: string;
  Keep: Boolean;
begin
  RIdx := 0;

  if FMasterList.Count > 0 then
  begin
    StringGrid1.RowCount := FMasterList.Count + 1;
    for i := 0 to FMasterList.Count - 1 do
    begin
      Cols := FMasterList[i].Split([',']);
      if Length(Cols) < 7 then Continue;

      IP := Cols[0];
      Country := Cols[2];
      Status := Cols[6];

      Keep := True;
      if FShowingWorkingOnly and (Status <> 'Работает!') then Keep := False;
      if Keep and (FFilterCountry <> '') and (Country <> FFilterCountry) then Keep := False;
      if Keep and FFavoritesOnly and (not IsFavorite(IP)) then Keep := False;
      if not Keep then Continue;

      Inc(RIdx);
      StringGrid1.Cells[0, RIdx] := IntToStr(RIdx);
      StringGrid1.Cells[1, RIdx] := Cols[0];
      StringGrid1.Cells[2, RIdx] := Cols[1];
      StringGrid1.Cells[3, RIdx] := Cols[2];
      StringGrid1.Cells[4, RIdx] := Cols[3];
      StringGrid1.Cells[5, RIdx] := Cols[4];
      StringGrid1.Cells[6, RIdx] := Cols[5];
      StringGrid1.Cells[7, RIdx] := Cols[6];
    end;
  end;

  if RIdx > 0 then
    StringGrid1.RowCount := RIdx + 1
  else
  begin
    StringGrid1.RowCount := 2;
    for i := 0 to 7 do
      StringGrid1.Cells[i, 1] := '';
  end;

  ApplySort;
  UpdateSortHeaders;
  UpdateStats;
end;

// Обновляет поле "Статус" (последнее из 7) в FMasterList для сервера с
// данным IP. Вызывается после проверки (единичной или массовой), чтобы
// результат не потерялся при следующей перестройке таблицы — например,
// при смене фильтра.
procedure TForm1.UpdateMasterStatus(const IP, NewStatus: string);
var
  i: Integer;
  Cols: TArray<string>;
begin
  for i := 0 to FMasterList.Count - 1 do
  begin
    Cols := FMasterList[i].Split([',']);
    if (Length(Cols) >= 7) and (Cols[0] = IP) then
    begin
      FMasterList[i] := Cols[0] + ',' + Cols[1] + ',' + Cols[2] + ',' +
        Cols[3] + ',' + Cols[4] + ',' + Cols[5] + ',' + NewStatus;
      Break;
    end;
  end;
end;

// Заполняет ComboCountry уникальными странами из FMasterList (плюс пункт
// "Все страны" сверху). Вызывается после каждой загрузки списка. Если
// страна, на которую был установлен фильтр, больше не встречается —
// сбрасывает его, а не оставляет таблицу молча пустой.
procedure TForm1.PopulateCountryCombo;
var
  i, Idx: Integer;
  Cols: TArray<string>;
  Countries: TStringList;
  PrevSelected: string;
begin
  PrevSelected := FFilterCountry;

  Countries := TStringList.Create;
  try
    Countries.Sorted := True;
    Countries.Duplicates := dupIgnore;
    for i := 0 to FMasterList.Count - 1 do
    begin
      Cols := FMasterList[i].Split([',']);
      if (Length(Cols) >= 7) and (Trim(Cols[2]) <> '') then
        Countries.Add(Cols[2]);
    end;

    ComboCountry.Items.BeginUpdate;
    try
      ComboCountry.Items.Clear;
      ComboCountry.Items.Add(AllCountriesLabel);
      ComboCountry.Items.AddStrings(Countries);
    finally
      ComboCountry.Items.EndUpdate;
    end;
  finally
    Countries.Free;
  end;

  if PrevSelected <> '' then
  begin
    Idx := ComboCountry.Items.IndexOf(PrevSelected);
    if Idx >= 0 then
      ComboCountry.ItemIndex := Idx
    else
    begin
      FFilterCountry := '';
      ComboCountry.ItemIndex := 0;
    end;
  end
  else
    ComboCountry.ItemIndex := 0;
end;

procedure TForm1.ComboCountryChange(Sender: TObject);
begin
  if ComboCountry.ItemIndex <= 0 then
    FFilterCountry := ''
  else
    FFilterCountry := ComboCountry.Items[ComboCountry.ItemIndex];
  RebuildGridFromMaster;
end;

procedure TForm1.ChkFavoritesOnlyClick(Sender: TObject);
begin
  FFavoritesOnly := ChkFavoritesOnly.Checked;
  RebuildGridFromMaster;
end;

// Читает favorites.txt (по одному IP в строке) рядом с исполняемым файлом.
// Список избранного не зависит от FMasterList и переживает обновления —
// сверяется по IP, а не по номеру строки.
procedure TForm1.LoadFavorites;
begin
  FreeAndNil(FFavorites);
  FFavorites := TStringList.Create;
  FFavorites.Sorted := True;
  FFavorites.Duplicates := dupIgnore;
  FFavorites.CaseSensitive := False;
  try
    if FileExists(ExtractFilePath(ParamStr(0)) + FavoritesFile) then
      FFavorites.LoadFromFile(ExtractFilePath(ParamStr(0)) + FavoritesFile);
  except
    // Файла может не быть при первом запуске — начинаем с пустого списка
  end;
end;

procedure TForm1.SaveFavorites;
begin
  try
    FFavorites.SaveToFile(ExtractFilePath(ParamStr(0)) + FavoritesFile);
  except
    // Не критично, если не удалось сохранить на диск
  end;
end;

function TForm1.IsFavorite(const IP: string): Boolean;
begin
  Result := Assigned(FFavorites) and (FFavorites.IndexOf(IP) >= 0);
end;

procedure TForm1.ToggleFavorite(const IP: string);
var
  Idx: Integer;
begin
  if (IP = '') or (not Assigned(FFavorites)) then Exit;

  Idx := FFavorites.IndexOf(IP);
  if Idx >= 0 then
    FFavorites.Delete(Idx)
  else
    FFavorites.Add(IP);

  SaveFavorites;

  if FFavoritesOnly then
    RebuildGridFromMaster // сервер мог как раз исчезнуть/появиться в отфильтрованном виде
  else
    StringGrid1.Invalidate; // иначе достаточно перерисовать маркер "★" у строки
end;

procedure TForm1.MenuToggleFavoriteClick(Sender: TObject);
var
  IP: string;
begin
  if (FContextRow <= 0) or (FContextRow >= StringGrid1.RowCount) then Exit;
  IP := Trim(StringGrid1.Cells[1, FContextRow]);
  ToggleFavorite(IP);
end;

procedure TForm1.ButtonInfoClick(Sender: TObject);
begin
  MessageDlg(
    'MyVPNGate — браузер и чекер публичных VPN-серверов VPN Gate.' + sLineBreak + sLineBreak +

    'Что делает программа:' + sLineBreak +
    '  • загружает актуальный список публичных серверов VPN Gate;' + sLineBreak +
    '  • проверяет их доступность (TCP-соединение) и показывает пинг, ' +
      'скорость и реальный протокол (TCP/UDP) каждого сервера;' + sLineBreak +
    '  • позволяет сохранить конфигурацию любого сервера в готовый файл .ovpn;' + sLineBreak +
    '  • умеет подключаться и отключаться от выбранного сервера прямо из ' +
      'программы через уже установленный SoftEther VPN Client, без ' +
      'переключения на другую программу.' + sLineBreak + sLineBreak +

    'Как пользоваться:' + sLineBreak +
    '  1. Кнопка «Обновить» — загрузить свежий список серверов.' + sLineBreak +
    '  2. Кнопка «Проверить серверы» — проверить доступность всех серверов ' +
      'из списка (можно и по одному — через контекстное меню).' + sLineBreak +
    '  3. Кнопка «Оставить только рабочие» — временно скрыть из таблицы ' +
      'серверы со статусом, отличным от «Работает!» (они не удаляются — ' +
      'повторное нажатие той же кнопки, теперь «Показать все серверы», ' +
      'возвращает их обратно).' + sLineBreak +
    '  4. Заголовки колонок IP / Порт / Страна / Пинг / Скорость кликабельны ' +
      '— сортируют таблицу, стрелка (▲/▼) показывает текущее направление.' + sLineBreak +
    '  5. Правая кнопка мыши на строке сервера — контекстное меню: ' +
      'скопировать IP или порт, перепроверить именно этот сервер, ' +
      'сохранить его .ovpn, подключиться или отключиться через SoftEther.' + sLineBreak +
    '  6. Строка сервера, к которому сейчас поднято SoftEther-подключение, ' +
      'подсвечивается зелёным и отмечается значком «●» рядом с IP.' + sLineBreak +
    '  7. В правой части статус-бара внизу окна — дата и время последнего ' +
      'обновления списка серверов кнопкой «Обновить».' + sLineBreak +
    '  8. Кнопка сворачивания окна прячет программу в трей (значок рядом с ' +
      'часами) вместо панели задач; вернуть окно — двойным кликом по ' +
      'значку или пунктом «Показать» его меню по правому клику.' + sLineBreak +
    '  9. Кнопка «Настройки» включает автоматическое обновление списка ' +
      'серверов по таймеру, позволяет задать интервал (в минутах) и ' +
      'запуск программы вместе с Windows (сразу свёрнутой в трей).' + sLineBreak +
    '  10. Список «Страна» и галочка «Только избранное» над таблицей ' +
      'фильтруют её по стране и/или показывают только отмеченные серверы.' + sLineBreak +
    '  11. Пункт контекстного меню «Добавить/Убрать из избранного» отмечает ' +
      'сервер значком «★» — такая отметка не пропадает при обновлении ' +
      'списка и сортировке (сверяется по IP).' + sLineBreak +
    '  12. Пункт «Быстрое подключение» в меню значка в трее сам выбирает ' +
      'сервер с лучшей заявленной скоростью среди проверенных рабочих и ' +
      'подключается к нему — без захода в окно программы. Если этот сервер ' +
      'на деле не подключается (бывает — публичные узлы VPN Gate ' +
      'непостоянны), программа сама пробует следующий по списку, и так до ' +
      '4 серверов подряд, прежде чем сообщить о неудаче.' + sLineBreak +
    '  13. Пока подключение активно, статус-бар (и подсказка значка в трее) ' +
      'каждые 10 секунд показывает пинг до сервера и следит, жива ли сама ' +
      'VPN-сессия; в «Настройках» можно включить автоматическое ' +
      'переподключение к другому серверу при обрыве связи.' + sLineBreak +
    '  14. Программа сама проверяет на GitHub, нет ли новой версии (тихо, ' +
      'при запуске), и предложит открыть страницу загрузки, если она есть. ' +
      'Проверить вручную можно пунктом «Проверить обновления программы» в ' +
      'меню значка в трее. Сама себя программа не обновляет — только ' +
      'сообщает о новой версии.' + sLineBreak +
    '  15. Пункт «QR-код для Android» в контекстном меню сервера показывает ' +
      'QR-код с его адресом и портом — для будущего Android-приложения ' +
      'MyVPNGate (сам .ovpn в QR не помещается, а обычный OpenVPN Connect ' +
      'такой QR не распознает).' + sLineBreak + sLineBreak +

    'Статус «Работает!» означает только то, что TCP-порт сервера принял ' +
    'соединение — это не гарантирует рабочий VPN-туннель. Если конкретный ' +
    'сервер не подключается, попробуйте другой из списка, желательно с ' +
    'меньшим пингом и большей скоростью.' + sLineBreak + sLineBreak +

    'Подключение через SoftEther требует отдельно установленного SoftEther ' +
    'VPN Client — сама программа VPN-туннель не реализует, только ' +
    'автоматизирует подключение к уже работающему клиенту. Если он не ' +
    'найден, а рядом с программой лежит файл ' + SoftEtherInstallerFile + ' — ' +
    'будет предложено сразу запустить его.',
    mtInformation, [mbOK], 0);
end;

procedure TForm1.StringGrid1DblClick(Sender: TObject);
var
  IP, FullAddress: string;
  Row: Integer;
begin
  Row := StringGrid1.Row;
  if Row > 0 then
  begin
    IP := StringGrid1.Cells[1, Row]; // IP находится во 2-й колонке (индекс 1)
    if Trim(IP) <> '' then
    begin
      FullAddress := IP;
      Clipboard.AsText := FullAddress;
      ShowMessage('Адрес ' + FullAddress + ' скопирован в буфер обмена!');
    end;
  end;
end;

procedure TForm1.StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer;
  Rect: TRect; State: TGridDrawState);
var
  IsConnectedRow: Boolean;
  CellText: string;
begin
  if ARow = 0 then Exit;

  // Строка сервера, к которому сейчас поднято SoftEther-подключение —
  // сверяем по IP (колонка 1), а не по номеру строки, чтобы отметка не
  // "слетала" при сортировке/обновлении списка.
  IsConnectedRow := (FConnectedServerIP <> '') and
    (Trim(StringGrid1.Cells[1, ARow]) = FConnectedServerIP);

  if gdSelected in State then
    StringGrid1.Canvas.Brush.Color := $003A3A3A
  else if IsConnectedRow then
    StringGrid1.Canvas.Brush.Color := $00335522 // подсветка активного VPN-подключения
  else if ARow mod 2 = 0 then
    StringGrid1.Canvas.Brush.Color := $00252525
  else
    StringGrid1.Canvas.Brush.Color := $001E1E1E;

  StringGrid1.Canvas.FillRect(Rect);

  // Цвет текста для колонки статуса (индекс 7)
  if ACol = 7 then
  begin
    if StringGrid1.Cells[ACol, ARow] = 'Работает!' then
      StringGrid1.Canvas.Font.Color := $0066CC33
    else if StringGrid1.Cells[ACol, ARow] = 'Недоступен' then
      StringGrid1.Canvas.Font.Color := $005555FF
    else if StringGrid1.Cells[ACol, ARow] = 'Проверка...' then
      StringGrid1.Canvas.Font.Color := $0033CCFF
    else
      StringGrid1.Canvas.Font.Color := clSilver;
    StringGrid1.Canvas.Font.Style := [fsBold];
  end
  else if IsConnectedRow and (ACol = 1) then
  begin
    StringGrid1.Canvas.Font.Color := $0066FF66;
    StringGrid1.Canvas.Font.Style := [fsBold];
  end
  else
  begin
    StringGrid1.Canvas.Font.Color := clWhite;
    StringGrid1.Canvas.Font.Style := [];
  end;

  // На IP-ячейке добавляем маркеры избранного/подключения — саму ячейку
  // (Cells[]) не трогаем, чтобы не сломать сортировку/сохранение/экспорт
  CellText := StringGrid1.Cells[ACol, ARow];
  if ACol = 1 then
  begin
    if IsFavorite(Trim(StringGrid1.Cells[1, ARow])) then
      CellText := Chr(9733) + ' ' + CellText; // ★
    if IsConnectedRow then
      CellText := Chr(9679) + ' ' + CellText; // ●
  end;

  StringGrid1.Canvas.TextRect(Rect, Rect.Left + 8, Rect.Top + 6, CellText);
end;

procedure TForm1.UpdateStats;
var
  i, Total, Working: Integer;
begin
  Total := 0;
  Working := 0;

  for i := 1 to StringGrid1.RowCount - 1 do
  begin
    if Trim(StringGrid1.Cells[1, i]) <> '' then
    begin
      Inc(Total);
      if StringGrid1.Cells[7, i] = 'Работает!' then
        Inc(Working);
    end;
  end;

  StatusBar1.Panels[0].Text := 'Всего серверов: ' + IntToStr(Total);
  StatusBar1.Panels[1].Text := 'Работает: ' + IntToStr(Working);
end;

// Отображает в шапке таблицы стрелку, указывающую текущую колонку и направление
// сортировки (вверх/вниз). Символы стрелок заданы кодами (#9650/#9660), чтобы не
// зависеть от кодировки исходного файла.
procedure TForm1.UpdateSortHeaders;
var
  c: Integer;
begin
  for c := 1 to 5 do
  begin
    if c = FSortColumn then
    begin
      if FSortAscending then
        StringGrid1.Cells[c, 0] := ColHeaderBase[c] + ' ' + Chr(9650)
      else
        StringGrid1.Cells[c, 0] := ColHeaderBase[c] + ' ' + Chr(9660);
    end
    else
      StringGrid1.Cells[c, 0] := ColHeaderBase[c];
  end;
end;

// Сортирует текущее содержимое таблицы по FSortColumn/FSortAscending —
// используется и по клику на шапку колонки, и при перестроении таблицы
// после смены фильтра (RebuildGridFromMaster), чтобы выбранная сортировка
// не сбрасывалась при переключении фильтров.
procedure TForm1.ApplySort;
var
  i, j: Integer;
  TempRow: TArray<string>;
  Swapped: Boolean;
  Direction, Cmp: Integer;
  Va, Vb: Double;
begin
  if FSortColumn = -1 then Exit;

  if FSortAscending then
    Direction := 1
  else
    Direction := -1;

  SetLength(TempRow, StringGrid1.ColCount);

  repeat
    Swapped := False;
    for i := 1 to StringGrid1.RowCount - 2 do
    begin
      if Trim(StringGrid1.Cells[1, i]) = '' then Break;

      // IP (1) — сравнение по октетам; Порт (2) и Пинг (4) — целые числа;
      // Скорость (5) — дробное число; Страна (3) — обычный текст
      case FSortColumn of
        1: Cmp := CompareIP(StringGrid1.Cells[FSortColumn, i], StringGrid1.Cells[FSortColumn, i + 1]);
        2, 4: Cmp := StrToIntDef(StringGrid1.Cells[FSortColumn, i], 0) -
                     StrToIntDef(StringGrid1.Cells[FSortColumn, i + 1], 0);
        5:
          begin
            Va := StrToFloatDef(StringGrid1.Cells[FSortColumn, i], 0);
            Vb := StrToFloatDef(StringGrid1.Cells[FSortColumn, i + 1], 0);
            if Va > Vb then Cmp := 1
            else if Va < Vb then Cmp := -1
            else Cmp := 0;
          end;
      else
        Cmp := AnsiCompareText(StringGrid1.Cells[FSortColumn, i], StringGrid1.Cells[FSortColumn, i + 1]);
      end;

      if Cmp * Direction > 0 then
      begin
        for j := 0 to StringGrid1.ColCount - 1 do
        begin
          TempRow[j] := StringGrid1.Cells[j, i];
          StringGrid1.Cells[j, i] := StringGrid1.Cells[j, i + 1];
          StringGrid1.Cells[j, i + 1] := TempRow[j];
        end;
        Swapped := True;
      end;
    end;
  until not Swapped;

  // Перенумеровываем колонку № (индекс 0) после сортировки
  for i := 1 to StringGrid1.RowCount - 1 do
  begin
    if Trim(StringGrid1.Cells[1, i]) <> '' then
      StringGrid1.Cells[0, i] := IntToStr(i)
    else
      StringGrid1.Cells[0, i] := '';
  end;
end;

procedure TForm1.StringGrid1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ACol, ARow: Integer;
  HasRow: Boolean;
  ScreenPt: TPoint;
begin
  StringGrid1.MouseToCell(X, Y, ACol, ARow);

  // Правая кнопка — показываем контекстное меню сами, по нажатию мыши.
  // Раньше это делалось через OnContextPopup (реагирует на WM_CONTEXTMENU),
  // но в некоторых конфигурациях VCL это сообщение до грида не доходит
  // вовсе, и ни выделение строки, ни меню не появлялись. OnMouseDown
  // срабатывает всегда, поэтому теперь используем только его.
  if Button = mbRight then
  begin
    if (ARow <= 0) or (ARow >= StringGrid1.RowCount) then Exit;

    StringGrid1.Row := ARow;
    FContextRow := ARow;

    HasRow := Trim(StringGrid1.Cells[1, ARow]) <> '';
    MenuCopyIP.Enabled := HasRow;
    MenuCopyPort.Enabled := HasRow;
    MenuRecheckServer.Enabled := HasRow;
    MenuSaveOvpn.Enabled := HasRow;
    MenuShowQR.Enabled := HasRow;
    MenuConnectSoftEther.Enabled := HasRow;

    MenuToggleFavorite.Enabled := HasRow;
    if HasRow and IsFavorite(Trim(StringGrid1.Cells[1, ARow])) then
      MenuToggleFavorite.Caption := 'Убрать из избранного'
    else
      MenuToggleFavorite.Caption := 'Добавить в избранное';

    // X, Y в OnMouseDown — координаты относительно самого грида (клиентские),
    // а Popup ждёт экранные — переводим через ClientToScreen.
    ScreenPt := StringGrid1.ClientToScreen(Point(X, Y));
    PopupMenu1.PopupComponent := StringGrid1;
    PopupMenu1.Popup(ScreenPt.X, ScreenPt.Y);
    Exit;
  end;

  if Button <> mbLeft then Exit;

  // Клик по шапке (строка 0) для колонок IP (1), Порт (2), Страна (3),
  // Пинг (4) и Скорость (5). Повторный клик по той же колонке меняет
  // направление сортировки.
  if (ARow = 0) and (ACol >= 1) and (ACol <= 5) then
  begin
    if FSortColumn = ACol then
      FSortAscending := not FSortAscending
    else
    begin
      FSortColumn := ACol;
      FSortAscending := True;
    end;

    ApplySort;
    UpdateSortHeaders;
  end;
end;

procedure TForm1.MenuCopyIPClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) then
    Clipboard.AsText := StringGrid1.Cells[1, FContextRow];
end;

procedure TForm1.MenuCopyPortClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) then
    Clipboard.AsText := StringGrid1.Cells[2, FContextRow];
end;

procedure TForm1.MenuRecheckServerClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) and
     (Trim(StringGrid1.Cells[1, FContextRow]) <> '') then
  begin
    StringGrid1.Cells[7, FContextRow] := 'Проверка...';
    TTCPCheckThread.Create(Self, FContextRow, StringGrid1.Cells[1, FContextRow],
      StrToIntDef(StringGrid1.Cells[2, FContextRow], 443));
  end;
end;

procedure TForm1.MenuSaveOvpnClick(Sender: TObject);
begin
  SaveOvpnForRow(FContextRow);
end;

// Сохраняет на диск декодированный .ovpn-конфиг сервера из строки ARow.
// Конфигурация доступна только для серверов, полученных при последнем
// обновлении списка (кнопка «Обновить») — именно тогда VPN Gate присылает
// закодированный в base64 OpenVPN-конфиг, который мы декодируем и храним
// в памяти для последующего экспорта.
procedure TForm1.SaveOvpnForRow(ARow: Integer);
var
  IP, Cfg: string;
begin
  if (ARow <= 0) or (ARow >= StringGrid1.RowCount) then Exit;

  IP := Trim(StringGrid1.Cells[1, ARow]);
  if IP = '' then Exit;

  if (FOvpnConfigs = nil) or (not FOvpnConfigs.TryGetValue(IP, Cfg)) or (Trim(Cfg) = '') then
  begin
    ShowMessage('Конфигурация .ovpn для ' + IP + ' недоступна. Сначала обновите список серверов кнопкой «Обновить».');
    Exit;
  end;

  SaveDialog1.FileName := IP + '.ovpn';
  if SaveDialog1.Execute then
  begin
    try
      TFile.WriteAllText(SaveDialog1.FileName, Cfg, TEncoding.UTF8);
      ShowMessage('Файл ' + ExtractFileName(SaveDialog1.FileName) + ' успешно сохранен.');
    except
      on E: Exception do
        ShowMessage('Не удалось сохранить файл: ' + E.Message);
    end;
  end;
end;

// QR специально кодирует только "IP:Порт" сервера, а не сам .ovpn целиком —
// у полного конфига внутри вшиты сертификат, ключ и CA (несколько КБ base64),
// это не помещается в надёжно сканируемый QR-код. Обычный OpenVPN Connect
// такой QR тоже не распознает — предполагается, что его будет читать
// отдельное будущее Android-приложение MyVPNGate, которое само достанет
// актуальный конфиг с сервера VPN Gate по этому IP в момент сканирования.
procedure TForm1.MenuShowQRClick(Sender: TObject);
var
  IP: string;
  Port: Integer;
begin
  if (FContextRow <= 0) or (FContextRow >= StringGrid1.RowCount) then Exit;
  IP := Trim(StringGrid1.Cells[1, FContextRow]);
  if IP = '' then Exit;

  Port := StrToIntDef(StringGrid1.Cells[2, FContextRow], 443);
  TQRCodeFetchThread.Create(Self, IP + ':' + IntToStr(Port));
end;

procedure TForm1.ShowServerQRCode(const QRText: string; const ImageBytes: TBytes; Success: Boolean);
var
  Dlg: TForm;
  Img: TImage;
  LblText, LblHint: TLabel;
  BtnClose: TButton;
  Stream: TMemoryStream;
  Png: TPngImage;
begin
  if not Success then
  begin
    ShowMessage('Не удалось получить QR-код. Проверьте подключение к интернету.');
    Exit;
  end;

  Dlg := TForm.Create(Self);
  try
    Dlg.Caption := 'QR-код сервера';
    Dlg.BorderStyle := bsDialog;
    Dlg.Position := poOwnerFormCenter;
    Dlg.Font := Self.Font;
    Dlg.ClientWidth := 340;
    Dlg.ClientHeight := 420;

    LblText := TLabel.Create(Dlg);
    LblText.Parent := Dlg;
    LblText.SetBounds(16, 16, 308, 16);
    LblText.Caption := QRText;
    LblText.Font.Style := [fsBold];

    Img := TImage.Create(Dlg);
    Img.Parent := Dlg;
    Img.SetBounds(20, 44, 300, 300);
    Img.Stretch := True;
    Img.Proportional := True;

    Stream := TMemoryStream.Create;
    try
      if Length(ImageBytes) > 0 then
        Stream.WriteBuffer(ImageBytes[0], Length(ImageBytes));
      Stream.Position := 0;
      Png := TPngImage.Create;
      try
        Png.LoadFromStream(Stream);
        Img.Picture.Graphic := Png;
      finally
        Png.Free;
      end;
    finally
      Stream.Free;
    end;

    LblHint := TLabel.Create(Dlg);
    LblHint.Parent := Dlg;
    LblHint.SetBounds(16, 352, 308, 32);
    LblHint.WordWrap := True;
    LblHint.Caption := 'QR-код содержит только IP и порт сервера — для будущего ' +
      'Android-приложения MyVPNGate. Обычным OpenVPN Connect его прочитать не получится.';

    BtnClose := TButton.Create(Dlg);
    BtnClose.Parent := Dlg;
    BtnClose.Caption := 'Закрыть';
    BtnClose.ModalResult := mrOk;
    BtnClose.Default := True;
    BtnClose.SetBounds(Dlg.ClientWidth - 96, Dlg.ClientHeight - 40, 80, 28);

    Dlg.ShowModal;
  finally
    Dlg.Free;
  end;
end;

// Показывает текст в третьей панели статус-бара (статус SoftEther-подключения)
procedure TForm1.SetVpnStatusText(const S: string);
begin
  if StatusBar1.Panels.Count > 2 then
    StatusBar1.Panels[2].Text := S;

  // Дублируем в подсказку значка трея — это единственное, что видно, пока
  // окно свёрнуто
  if S = '' then
    TrayIcon1.Hint := 'MyVPNGate'
  else
    TrayIcon1.Hint := 'MyVPNGate' + sLineBreak + S;
end;

// Запоминает IP сервера, к которому сейчас поднято SoftEther-подключение
// (пустая строка — подключения нет), и просит таблицу перерисоваться, чтобы
// строка с этим IP сразу подсветилась в StringGrid1DrawCell. Храним именно
// IP, а не номер строки — номер после сортировки/обновления списка теряет
// смысл, а IP остаётся верным ориентиром независимо от порядка строк.
procedure TForm1.SetConnectedServerIP(const IP: string);
begin
  FConnectedServerIP := IP;

  // Новое "поколение" отменяет результаты любых проверок связи, запущенных
  // для предыдущего состояния (см. TConnectionMonitorThread), и запускает
  // (или останавливает) сам мониторинг
  Inc(FConnectionGeneration);
  FConsecutiveDrops := 0;
  FReconnecting := False;
  PingTimer.Enabled := (IP <> '');

  // Реальное подключение состоялось — если оно шло через каскад перебора
  // серверов, он своё дело сделал и больше не нужен. Проверяем именно
  // IP <> '', а не полагаемся на сам факт вызова: TSoftEtherThread вызывает
  // этот же метод с '' и в начале КАЖДОЙ попытки (чтобы снять старую
  // отметку) — если чистить каскад и на это тоже, он оборвётся на первом
  // же шаге.
  if IP <> '' then
    FreeAndNil(FCascadeAttemptIPs);

  StringGrid1.Invalidate;
end;

// Находит vpncmd.exe (утилита управления SoftEther VPN Client): сначала
// проверяет путь, сохранённый при прошлом запуске, затем стандартные пути
// установки, и только если не нашла — один раз спрашивает пользователя и
// запоминает выбранный путь на будущее.
function TForm1.LocateVpnCmd: string;
const
  CommonPaths: array[0..1] of string = (
    'C:\Program Files\SoftEther VPN Client\vpncmd.exe',
    'C:\Program Files (x86)\SoftEther VPN Client\vpncmd.exe'
  );
var
  CacheFile, Candidate, InstallerPath: string;
  SL: TStringList;
  i: Integer;
begin
  Result := '';

  CacheFile := ExtractFilePath(ParamStr(0)) + VpnCmdPathCacheFile;
  if FileExists(CacheFile) then
  begin
    SL := TStringList.Create;
    try
      SL.LoadFromFile(CacheFile);
      if SL.Count > 0 then
      begin
        Candidate := Trim(SL[0]);
        if (Candidate <> '') and FileExists(Candidate) then
          Exit(Candidate);
      end;
    finally
      SL.Free;
    end;
  end;

  for i := 0 to High(CommonPaths) do
    if FileExists(CommonPaths[i]) then
      Exit(CommonPaths[i]);

  // SoftEther VPN Client не найден. Если рядом с программой лежит его
  // установщик (SoftEtherInstallerFile) — предлагаем запустить именно его,
  // вместо того чтобы сразу отправлять пользователя искать vpncmd.exe
  // вручную. Сам установщик — окно другого приложения, ждать его завершения
  // тут не пытаемся: пользователь ставит SoftEther в своём темпе и заново
  // нажимает на нужное действие после установки.
  InstallerPath := ExtractFilePath(ParamStr(0)) + SoftEtherInstallerFile;
  if FileExists(InstallerPath) then
  begin
    if MessageDlg('SoftEther VPN Client не найден — похоже, он ещё не установлен. ' +
         'Рядом с программой есть его установщик. Запустить его сейчас?' + sLineBreak + sLineBreak +
         'После установки нажмите на это же действие ещё раз.',
         mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      try
        ShellExecute(0, nil, PChar(InstallerPath), nil,
          PChar(ExtractFilePath(InstallerPath)), SW_SHOWNORMAL);
      except
        on E: Exception do
          ShowMessage('Не удалось запустить установщик: ' + E.Message);
      end;
      Exit(''); // vpncmd.exe появится только после того, как установка реально завершится
    end;
  end;

  if MessageDlg('Не найден vpncmd.exe (утилита SoftEther VPN Client). Указать путь к нему вручную?',
       mtConfirmation, [mbYes, mbNo], 0) = mrYes then
  begin
    if OpenDialog1.Execute then
    begin
      Result := OpenDialog1.FileName;
      SL := TStringList.Create;
      try
        SL.Add(Result);
        SL.SaveToFile(CacheFile);
      finally
        SL.Free;
      end;
    end;
  end;
end;

// Настройка аккаунта SoftEther через vpncmd требует повышенных прав — без
// них AccountCreate/AccountSet отрабатывают "успешно", но по факту ничего
// не сохраняют. Если прав нет, один раз предлагаем перезапуститься через UAC.
function TForm1.EnsureElevatedForSoftEther: Boolean;
begin
  Result := IsRunningElevated;
  if not Result then
  begin
    if MessageDlg('Настройка подключения SoftEther требует прав администратора. ' +
         'Перезапустить программу от имени администратора?',
         mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      RelaunchElevated; // при согласии текущий процесс завершится сам
  end;
end;

procedure TForm1.MenuConnectSoftEtherClick(Sender: TObject);
var
  IP: string;
  Port: Integer;
begin
  if (FContextRow <= 0) or (FContextRow >= StringGrid1.RowCount) then Exit;
  IP := Trim(StringGrid1.Cells[1, FContextRow]);
  if IP = '' then Exit;

  // Порт из таблицы (тот же, что и для OpenVPN) — на практике публичные узлы
  // VPN Gate слушают нативный протокол SoftEther на том же порту, что и
  // OpenVPN (одно и то же соединение определяет протокол по первым байтам).
  // Фиксированный 443 подходит не всегда — подтверждено на практике: с ним
  // подключение к части серверов не проходит, а с их собственным портом — да.
  Port := StrToIntDef(StringGrid1.Cells[2, FContextRow], 443);
  // ...но только если это TCP-порт: у серверов с протоколом UDP в таблице
  // стоит UDP-порт OpenVPN, а SoftEther подключается исключительно по TCP —
  // на UDP-порт такое подключение не пройдёт никогда. Для них берём 443,
  // который публичные узлы VPN Gate слушают по умолчанию.
  if SameText(Trim(StringGrid1.Cells[6, FContextRow]), 'UDP') then
    Port := 443;

  // Явный ручной выбор конкретного сервера — если вдруг ещё шёл каскад
  // перебора (например, от предыдущего «Быстрого подключения»), он тут
  // неуместен: пользователь сам выбрал сервер, подменять его не нужно.
  FreeAndNil(FCascadeAttemptIPs);
  ConnectToServer(IP, Port);
end;

// Общая точка входа для подключения через SoftEther — используется и
// контекстным меню, и «Быстрым подключением» из трея, и автопереподключением
procedure TForm1.ConnectToServer(const IP: string; APort: Integer);
begin
  if IP = '' then Exit;
  if not EnsureElevatedForSoftEther then Exit;

  if FVpnCmdPath = '' then
    FVpnCmdPath := LocateVpnCmd;
  if FVpnCmdPath = '' then
  begin
    ShowMessage('Без vpncmd.exe автоматическое подключение через SoftEther недоступно.');
    Exit;
  end;

  TSoftEtherThread.Create(Self, seaConnect, IP, APort);
end;

// Находит в FMasterList сервер со статусом «Работает!» с наибольшей
// заявленной скоростью (пинг — как второй критерий при равной скорости).
// ExcludeIP позволяет исключить конкретный сервер — например, тот, с
// которым только что оборвалась связь, при автопереподключении.
function TForm1.FindBestServerRow(out IP: string; out Port: Integer; const ExcludeIP: string;
  ExcludeIPs: TStrings): Boolean;
var
  i: Integer;
  Cols: TArray<string>;
  Speed: Double;
  Ping: Integer;
  BestSpeed: Double;
  BestPing: Integer;
begin
  Result := False;
  IP := '';
  Port := 0;
  BestSpeed := -1;
  BestPing := MaxInt;

  for i := 0 to FMasterList.Count - 1 do
  begin
    Cols := FMasterList[i].Split([',']);
    if Length(Cols) < 7 then Continue;
    if Cols[6] <> 'Работает!' then Continue;
    if (ExcludeIP <> '') and (Cols[0] = ExcludeIP) then Continue;
    if Assigned(ExcludeIPs) and (ExcludeIPs.IndexOf(Cols[0]) >= 0) then Continue;

    Speed := StrToFloatDef(Cols[4], 0);
    Ping := StrToIntDef(Cols[3], MaxInt);

    if (not Result) or (Speed > BestSpeed) or
       ((Speed = BestSpeed) and (Ping < BestPing)) then
    begin
      BestSpeed := Speed;
      BestPing := Ping;
      IP := Cols[0];
      Port := StrToIntDef(Cols[1], 443);
      if SameText(Cols[5], 'UDP') then
        Port := 443; // SoftEther работает только по TCP (см. MenuConnectSoftEtherClick)
      Result := True;
    end;
  end;
end;

procedure TForm1.MenuTrayQuickConnectClick(Sender: TObject);
var
  IP: string;
  Port: Integer;
begin
  if not FindBestServerRow(IP, Port) then
  begin
    ShowMessage('Нет ни одного проверенного рабочего сервера. Сначала нажмите «Проверить серверы».');
    Exit;
  end;
  StartCascadeConnect('');
end;

procedure TForm1.MenuTrayCheckUpdateClick(Sender: TObject);
begin
  TAppUpdateCheckThread.Create(Self, False);
end;

// Подбирает следующий лучший сервер (кроме того, с которым только что
// оборвалась связь) и переподключается к нему
procedure TForm1.ReconnectToNextBestServer(const ExcludeIP: string);
begin
  StartCascadeConnect(ExcludeIP);
end;

// Запускает перебор рабочих серверов: пробует лучший по заявленной скорости,
// и если он не подключается (см. HandleConnectAttemptFailed) — следующий, и
// так до MaxCascadeAttempts раз. Используется «Быстрым подключением» и
// автопереподключением при обрыве; обычное подключение к конкретному
// серверу из контекстного меню каскад не запускает — там сервер выбирает
// сам пользователь, и подменять его молча было бы неожиданно.
procedure TForm1.StartCascadeConnect(const InitialExcludeIP: string);
const
  MaxCascadeAttempts = 4; // сколько разных серверов подряд пробуем, прежде чем сдаться
begin
  FreeAndNil(FCascadeAttemptIPs);
  FCascadeAttemptIPs := TStringList.Create;
  if InitialExcludeIP <> '' then
    FCascadeAttemptIPs.Add(InitialExcludeIP);
  FCascadeRemaining := MaxCascadeAttempts;
  TryNextCascadeCandidate;
end;

procedure TForm1.TryNextCascadeCandidate;
var
  IP: string;
  Port: Integer;
begin
  if not Assigned(FCascadeAttemptIPs) then Exit;

  if FCascadeRemaining <= 0 then
  begin
    SetVpnStatusText('VPN: не удалось подключиться ни к одному из проверенных серверов');
    FreeAndNil(FCascadeAttemptIPs);
    Exit;
  end;

  if not FindBestServerRow(IP, Port, '', FCascadeAttemptIPs) then
  begin
    SetVpnStatusText('VPN: больше нет проверенных рабочих серверов для подключения');
    FreeAndNil(FCascadeAttemptIPs);
    Exit;
  end;

  FCascadeAttemptIPs.Add(IP);
  Dec(FCascadeRemaining);
  ConnectToServer(IP, Port);
end;

// Вызывается, когда ИМЕННО ЭТА попытка подключения провалилась (см.
// TSoftEtherThread.SyncConnectFailed) — если она была частью каскада,
// пробуем следующий сервер; если нет (ручной выбор из контекстного меню) —
// ничего не делаем, пользователь уже увидел текст ошибки в статус-баре.
procedure TForm1.HandleConnectAttemptFailed(const FailedIP: string);
begin
  if not Assigned(FCascadeAttemptIPs) then Exit;
  TryNextCascadeCandidate;
end;

// Результат фоновой проверки активного подключения (см.
// TConnectionMonitorThread) — решает, жива ли связь, и что делать при обрыве
procedure TForm1.HandleMonitorResult(SessionAlive: Boolean; const PingText: string);
const
  MaxConsecutiveDrops = 2; // подряд неудачных проверок, прежде чем считать связь оборванной
var
  FailedIP: string;
begin
  if SessionAlive then
  begin
    FConsecutiveDrops := 0;
    SetVpnStatusText('VPN: подключено к ' + FConnectedServerIP + ' (пинг: ' + PingText + ' мс)');
    Exit;
  end;

  Inc(FConsecutiveDrops);

  if FConsecutiveDrops < MaxConsecutiveDrops then
  begin
    SetVpnStatusText('VPN: ' + FConnectedServerIP + ' не отвечает, проверяю...');
    Exit;
  end;

  if FReconnecting then Exit; // переподключение уже запущено этой же серией неудачных проверок

  FailedIP := FConnectedServerIP;
  if FAutoReconnectEnabled then
  begin
    FReconnecting := True;
    SetVpnStatusText('VPN: связь с ' + FailedIP + ' потеряна, переподключение...');
    ReconnectToNextBestServer(FailedIP);
  end
  else
  begin
    SetVpnStatusText('VPN: связь с ' + FailedIP + ' потеряна');
    SetConnectedServerIP(''); // сама VPN-сессия может остаться висеть — это лишь снимает отметку в программе
  end;
end;

procedure TForm1.PingTimerTimer(Sender: TObject);
begin
  if FConnectedServerIP = '' then Exit;
  TConnectionMonitorThread.Create(Self, FConnectedServerIP, FConnectionGeneration);
end;

procedure TForm1.MenuDisconnectSoftEtherClick(Sender: TObject);
begin
  if not EnsureElevatedForSoftEther then Exit;

  if FVpnCmdPath = '' then
    FVpnCmdPath := LocateVpnCmd;
  if FVpnCmdPath = '' then Exit;

  FreeAndNil(FCascadeAttemptIPs); // ручное отключение останавливает и каскад перебора, если он шёл
  TSoftEtherThread.Create(Self, seaDisconnect, '', 0);
end;

procedure TForm1.NetHTTPClient1ValidateServerCertificate(const Sender: TObject;
  const ARequest: TURLRequest; const Certificate: TCertificate;
  var Accepted: Boolean);
begin
  Accepted := True;
end;

// Сохраняет FMasterList (полный список, независимо от текущих фильтров) —
// а не содержимое таблицы, которое может быть отфильтрованным подмножеством
procedure TForm1.SaveListToFile;
begin
  try
    FMasterList.SaveToFile(ExtractFilePath(ParamStr(0)) + 'servers.txt');
  except
    // Не критично, если не удалось сохранить — при следующем успешном
    // обновлении список на диске всё равно перезапишется
  end;
end;

{ TUpdateThread }

constructor TUpdateThread.Create(AForm: TForm1; AIsAuto: Boolean);
begin
  FForm := AForm;
  FIsAuto := AIsAuto;
  FTempServers := TStringList.Create;
  FTempOvpn := TDictionary<string, string>.Create;
  FSuccess := False;
  inherited Create(False);
  FreeOnTerminate := True;
end;

destructor TUpdateThread.Destroy;
begin
  FTempServers.Free;
  FTempOvpn.Free;
  inherited;
end;

procedure TUpdateThread.Execute;
var
  Client: TNetHTTPClient;
  CSVData, OVPN, PortStr, Country, PingStr, SpeedStr: string;
  Protocol, ProtoRaw, LineTrim: string;
  RemoteParts: TArray<string>;
  Lines, Columns, OVPNLines: TStringList;
  i, j: Integer;
  SpeedBps, SpeedTenths: Int64;
  FoundRemote: Boolean;
begin
  Client := TNetHTTPClient.Create(nil);
  Lines := TStringList.Create;
  Columns := TStringList.Create;
  OVPNLines := TStringList.Create;
  Columns.StrictDelimiter := True;
  Columns.Delimiter := ',';
  try
    try
      Client.UserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36';
      CSVData := Client.Get('https://www.vpngate.net/api/iphone/').ContentAsString();
      FSuccess := True;
    except
      on E: Exception do
      begin
        FErrorMessage := E.Message;
        FSuccess := False;
      end;
    end;

    if FSuccess then
    begin
      Lines.Text := CSVData;
      for i := 0 to Lines.Count - 1 do
      begin
        if (Trim(Lines[i]) = '') or (Lines[i][1] = '*') then Continue;
        Columns.DelimitedText := Lines[i];
        if (Columns.Count > 1) and (Columns[1] = 'IP') then Continue;

        if Columns.Count > 14 then
        begin
          PortStr := '443';
          Country := 'Unknown';
          if Columns.Count > 5 then
            Country := Columns[5]; // Название страны

          // Пинг (мс) — колонка 3 исходного CSV VPN Gate
          PingStr := '-';
          if (Columns.Count > 3) and (Trim(Columns[3]) <> '') then
            PingStr := Trim(Columns[3]);

          // Скорость (колонка 4, бит/с) — переводим в Мбит/с (десятые доли).
          // Точка как разделитель дробной части задаётся вручную, без
          // FormatFloat: он берёт разделитель из региональных настроек
          // Windows, и на русской локали это запятая — а запятая внутри
          // значения ломает разбор CSV-строки FTempServers ниже и сдвигает
          // все последующие поля (Пинг/Скорость/Протокол/Статус).
          SpeedStr := '-';
          if Columns.Count > 4 then
          begin
            SpeedBps := StrToInt64Def(Trim(Columns[4]), 0);
            if SpeedBps > 0 then
            begin
              SpeedTenths := Round(SpeedBps / 100000);
              SpeedStr := IntToStr(SpeedTenths div 10) + '.' + IntToStr(SpeedTenths mod 10);
            end;
          end;

          // По умолчанию OpenVPN использует UDP, если явно не указано иное —
          // это значение подменяется ниже, если конфиг сервера говорит другое
          Protocol := 'UDP';

          OVPN := '';
          FoundRemote := False;
          try
            OVPN := TNetEncoding.Base64.Decode(Columns[14]);
            OVPNLines.Text := OVPN;

            // Директива "proto" может стоять как до, так и после "remote",
            // поэтому дочитываем файл целиком, а не выходим по первой строке
            for j := 0 to OVPNLines.Count - 1 do
            begin
              LineTrim := Trim(OVPNLines[j]);

              // Отдельная директива "proto tcp-client" / "proto udp" и т.п.
              if Pos('proto ', LineTrim) = 1 then
              begin
                ProtoRaw := LowerCase(Trim(Copy(LineTrim, 7, MaxInt)));
                if Pos('tcp', ProtoRaw) = 1 then
                  Protocol := 'TCP'
                else if Pos('udp', ProtoRaw) = 1 then
                  Protocol := 'UDP';
              end;

              // Берём порт (и протокол, если он указан прямо тут) из первой
              // строки "remote" — конфиг может перечислять несколько
              if (not FoundRemote) and (Pos('remote ', LineTrim) = 1) then
              begin
                // Формат строки: "remote <ip> <порт> [proto]"
                RemoteParts := Trim(Copy(LineTrim, 8, MaxInt)).Split([' ']);
                if Length(RemoteParts) >= 2 then
                  PortStr := Trim(RemoteParts[1]);
                if Length(RemoteParts) >= 3 then
                begin
                  ProtoRaw := LowerCase(Trim(RemoteParts[2]));
                  if Pos('tcp', ProtoRaw) = 1 then
                    Protocol := 'TCP'
                  else if Pos('udp', ProtoRaw) = 1 then
                    Protocol := 'UDP';
                end;
                FoundRemote := True;
              end;
            end;
          except
          end;

          // Сохраняем во временный список: IP, Порт, Страна, Пинг, Скорость, Протокол, Статус
          FTempServers.Add(Columns[1] + ',' + PortStr + ',' + Country + ',' +
            PingStr + ',' + SpeedStr + ',' + Protocol + ',Ожидание');

          // Сохраняем декодированный OpenVPN-конфиг для последующего экспорта в .ovpn
          if (OVPN <> '') and (Trim(Columns[1]) <> '') then
            FTempOvpn.AddOrSetValue(Columns[1], OVPN);
        end;
      end;
    end;
  finally
    Client.Free;
    Lines.Free;
    Columns.Free;
    OVPNLines.Free;
  end;

  // Безопасно передаем данные в главный поток для отрисовки (выполняется всегда,
  // в том числе при ошибке загрузки, чтобы скрыть прогресс-бар и показать причину)
  Synchronize(UpdateUI);
end;

procedure TUpdateThread.UpdateUI;
var
  i: Integer;
  UpdatedText: string;
begin
  // Возвращаем кнопку на место и скрываем прогресс-бар
  FForm.ProgressBar1.Visible := False;
  FForm.Button1.Visible := True;

  if not FSuccess then
  begin
    // При автообновлении по таймеру всплывающее окно не показываем — оно
    // будет мешать, если программа в этот момент свёрнута в трей или просто
    // работает в фоне; следующая попытка всё равно произойдёт по таймеру
    if not FIsAuto then
      ShowMessage('Ошибка скачивания: ' + FErrorMessage);
    Exit;
  end;

  // Список действительно загрузился — теперь можно сбросить старый фильтр
  // «Оставить только рабочие»: у всех свежих серверов статус ещё "Ожидание",
  // и показывать сразу пустую таблицу в этом фильтре было бы странно.
  // Фильтр по стране и «Только избранное» — не связаны со статусом проверки,
  // их не трогаем (PopulateCountryCombo сам сбросит страну, если она вдруг
  // пропала из нового списка).
  FForm.FShowingWorkingOnly := False;
  FForm.Button3.Caption := 'Оставить только рабочие';

  FForm.FMasterList.Clear;
  for i := 0 to FTempServers.Count - 1 do
    FForm.FMasterList.Add(FTempServers[i]);

  // Передаем свежесобранный словарь .ovpn-конфигов форме (используется контекстным
  // меню «Сохранить .ovpn файл») и освобождаем предыдущий
  FreeAndNil(FForm.FOvpnConfigs);
  FForm.FOvpnConfigs := FTempOvpn;
  FTempOvpn := nil;

  // Свежий список ещё не отсортирован — сбрасываем стрелку в шапке таблицы
  FForm.FSortColumn := -1;

  FForm.PopulateCountryCombo;
  FForm.RebuildGridFromMaster; // сама вызывает UpdateSortHeaders/UpdateStats

  FForm.SaveListToFile;

  // Отмечаем момент успешного обновления — и на экране, и на диске, чтобы
  // при следующем запуске программы было видно, насколько свежий список
  UpdatedText := FormatDateTime('dd.mm.yyyy hh:nn', Now);
  if FForm.StatusBar1.Panels.Count > 3 then
    FForm.StatusBar1.Panels[3].Text := 'Обновлено: ' + UpdatedText;
  try
    TFile.WriteAllText(ExtractFilePath(ParamStr(0)) + ServersUpdatedFile, UpdatedText);
  except
    // Не критично, если не удалось сохранить — статус-бар всё равно покажет актуальную дату
  end;
end;

end.
