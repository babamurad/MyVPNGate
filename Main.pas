unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, IdBaseComponent, IdComponent,
  IdTCPConnection, IdTCPClient, IdHTTP, Vcl.Grids, Vcl.StdCtrls, Vcl.ExtCtrls,
  Clipbrd, System.NetEncoding,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent,
  Vcl.ComCtrls, System.ImageList, Vcl.ImgList, Vcl.Menus,
  System.Generics.Collections, System.IOUtils;

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
    FTempServers: TStringList;
    FTempOvpn: TDictionary<string, string>;
    procedure UpdateUI;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1);
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
    procedure SyncStatus;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TForm1; AAction: TSoftEtherAction; const AServerIP: string; AServerPort: Integer);
  end;

  TForm1 = class(TForm)
    Panel1: TPanel;
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
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
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
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
  private
    FOvpnConfigs: TDictionary<string, string>; // IP -> декодированный .ovpn (заполняется при обновлении списка)
    FContextRow: Integer;                      // Строка, по которой кликнули правой кнопкой (для контекстного меню)
    FSortColumn: Integer;                      // Текущая колонка сортировки (-1 — нет)
    FSortAscending: Boolean;                   // Направление текущей сортировки
    FVpnCmdPath: string;                       // Путь к vpncmd.exe (SoftEther VPN Client), находится один раз
    procedure SaveListToFile;
    procedure UpdateStats;
    procedure UpdateSortHeaders;
    procedure SaveOvpnForRow(ARow: Integer);
    function LocateVpnCmd: string;
    procedure SetVpnStatusText(const S: string);
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

const
  // Настройки автоматического подключения через SoftEther (публичные узлы
  // VPN Gate работают через фиксированный хаб и служебную пару логин/пароль)
  SoftEtherHubName = 'VPNGATE';
  SoftEtherUser = 'vpn';
  SoftEtherPassword = 'vpn';
  SoftEtherAccountName = 'MyVPNGateQuick'; // одно и то же имя переиспользуется под любой сервер
  SoftEtherNicName = 'VPN'; // имя виртуального адаптера по умолчанию у SoftEther VPN Client Manager
  VpnCmdPathCacheFile = 'vpncmd_path.txt';

// Запускает внешний процесс, скрыто (без окна), и возвращает весь его
// стандартный вывод (stdout+stderr) одной строкой. Используется для вызова
// vpncmd.exe — своего готового аналога в VCL (наподобие TProcess) нет,
// поэтому напрямую через WinAPI (CreateProcess + анонимный pipe).
function RunProcessCapture(const CommandLine: string; TimeoutMs: Cardinal; out Output: string): Boolean;
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
function RunVpnCmd(const VpnCmdExe, Args: string; out Output: string): Boolean;
begin
  Result := RunProcessCapture('"' + VpnCmdExe + '" localhost /CLIENT /CMD ' + Args, 15000, Output);
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
end;

procedure TSoftEtherThread.SyncStatus;
begin
  FForm.SetVpnStatusText(FStatusText);
end;

procedure TSoftEtherThread.Execute;
var
  Output, LowerOutput: string;
  Attempt: Integer;
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
    RunVpnCmd(FForm.FVpnCmdPath, 'AccountDisconnect ' + SoftEtherAccountName, Output);
    FStatusText := 'VPN: отключено';
    Synchronize(SyncStatus);
    Exit;
  end;

  // seaConnect
  FStatusText := 'VPN: настройка подключения к ' + FServerIP + '...';
  Synchronize(SyncStatus);

  // На случай, если уже была активна предыдущая попытка/сессия
  RunVpnCmd(FForm.FVpnCmdPath, 'AccountDisconnect ' + SoftEtherAccountName, Output);

  // Пробуем обновить уже существующий аккаунт под новый сервер; если его ещё
  // нет — создаём. AccountSet возвращает ошибку, если аккаунта не существует.
  if not RunVpnCmd(FForm.FVpnCmdPath, Format(
       'AccountSet %s /SERVER:%s:%d /HUB:%s /USERNAME:%s /NICNAME:%s',
       [SoftEtherAccountName, FServerIP, FServerPort, SoftEtherHubName, SoftEtherUser, SoftEtherNicName]),
       Output)
     or (Pos('error', LowerCase(Output)) > 0) then
  begin
    RunVpnCmd(FForm.FVpnCmdPath, Format(
      'AccountCreate %s /SERVER:%s:%d /HUB:%s /USERNAME:%s /NICNAME:%s',
      [SoftEtherAccountName, FServerIP, FServerPort, SoftEtherHubName, SoftEtherUser, SoftEtherNicName]),
      Output);
  end;

  RunVpnCmd(FForm.FVpnCmdPath, Format('AccountPasswordSet %s /PASSWORD:%s /TYPE:standard',
    [SoftEtherAccountName, SoftEtherPassword]), Output);

  RunVpnCmd(FForm.FVpnCmdPath, 'AccountConnect ' + SoftEtherAccountName, Output);

  FStatusText := 'VPN: подключение к ' + FServerIP + '...';
  Synchronize(SyncStatus);

  Connected := False;
  Failed := False;
  for Attempt := 1 to 20 do // ждём подключения до ~20 секунд
  begin
    Sleep(1000);
    RunVpnCmd(FForm.FVpnCmdPath, 'AccountStatusGet ' + SoftEtherAccountName, Output);
    LowerOutput := LowerCase(Output);

    // "disconnected" тоже содержит подстроку "connected" — проверяем его первым
    if (Pos('disconnected', LowerOutput) = 0) and (Pos('connected', LowerOutput) > 0) then
    begin
      Connected := True;
      Break;
    end;

    if (Pos('error occurred', LowerOutput) > 0) or (Pos('connection failed', LowerOutput) > 0) then
    begin
      Failed := True;
      Break;
    end;
  end;

  if Connected then
    FStatusText := 'VPN: подключено к ' + FServerIP
  else if Failed then
    FStatusText := 'VPN: ошибка подключения к ' + FServerIP
  else
    FStatusText := 'VPN: не удалось подключиться за отведённое время';

  Synchronize(SyncStatus);
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
begin
  // Безопасно обновляем статус в колонке "Статус" (индекс 7) для конкретной строки
  if FRowIndex < FForm.StringGrid1.RowCount then
    FForm.StringGrid1.Cells[7, FRowIndex] := FStatus;
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
  RowIdx: Integer;
begin
  StringGrid1.ColCount := 8;
  StringGrid1.FixedRows := 1;
  StringGrid1.RowCount := 2;

  FOvpnConfigs := TDictionary<string, string>.Create;
  FContextRow := -1;
  FSortColumn := -1;
  FSortAscending := True;
  FVpnCmdPath := ''; // находим лениво, при первом обращении к SoftEther

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

  FilePath := ExtractFilePath(ParamStr(0)) + 'servers.txt';
  if not FileExists(FilePath) then Exit;

  SL := TStringList.Create;
  Columns := TStringList.Create;
  Columns.StrictDelimiter := True;
  Columns.Delimiter := ',';

  try
    SL.LoadFromFile(FilePath);
    if SL.Count > 0 then
      StringGrid1.RowCount := SL.Count + 1;

    RowIdx := 0;
    for i := 0 to SL.Count - 1 do
    begin
      if Trim(SL[i]) = '' then Continue;
      Columns.DelimitedText := SL[i];
      if Columns.Count >= 7 then
      begin
        Inc(RowIdx);
        StringGrid1.Cells[0, RowIdx] := IntToStr(RowIdx);
        StringGrid1.Cells[1, RowIdx] := Columns[0]; // IP
        StringGrid1.Cells[2, RowIdx] := Columns[1]; // Порт
        StringGrid1.Cells[3, RowIdx] := Columns[2]; // Страна
        StringGrid1.Cells[4, RowIdx] := Columns[3]; // Пинг
        StringGrid1.Cells[5, RowIdx] := Columns[4]; // Скорость
        StringGrid1.Cells[6, RowIdx] := Columns[5]; // Протокол
        StringGrid1.Cells[7, RowIdx] := Columns[6]; // Статус
      end;
    end;

    if RowIdx > 0 then
      StringGrid1.RowCount := RowIdx + 1
    else
      StringGrid1.RowCount := 2;
  finally
    SL.Free;
    Columns.Free;
  end;

  UpdateStats;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FOvpnConfigs.Free;
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
  // Прячем кнопку, чтобы исключить повторные нажатия
  Button1.Visible := False;

  // Показываем прогресс-бар ровно на месте кнопки
  ProgressBar1.Left := Button1.Left;
  ProgressBar1.Top := Button1.Top;
  ProgressBar1.Width := Button1.Width;
  ProgressBar1.Height := Button1.Height;
  ProgressBar1.Visible := True;

  // Запускаем фоновую загрузку
  TUpdateThread.Create(Self);
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

procedure TForm1.Button3Click(Sender: TObject);
var
  i: Integer;
  TempList: TStringList;
  Cols: TArray<string>;
  RIdx: Integer;
begin
  TempList := TStringList.Create;
  try
    for i := 1 to StringGrid1.RowCount - 1 do
    begin
      if StringGrid1.Cells[7, i] = 'Работает!' then
      begin
        TempList.Add(StringGrid1.Cells[1, i] + ',' + // IP
                     StringGrid1.Cells[2, i] + ',' + // Порт
                     StringGrid1.Cells[3, i] + ',' + // Страна
                     StringGrid1.Cells[4, i] + ',' + // Пинг
                     StringGrid1.Cells[5, i] + ',' + // Скорость
                     StringGrid1.Cells[6, i] + ',' + // Протокол
                     StringGrid1.Cells[7, i]);       // Статус
      end;
    end;

    if TempList.Count > 0 then
      StringGrid1.RowCount := TempList.Count + 1
    else
    begin
      StringGrid1.RowCount := 2;
      StringGrid1.Cells[0, 1] := '';
      StringGrid1.Cells[1, 1] := '';
      StringGrid1.Cells[2, 1] := '';
      StringGrid1.Cells[3, 1] := '';
      StringGrid1.Cells[4, 1] := '';
      StringGrid1.Cells[5, 1] := '';
      StringGrid1.Cells[6, 1] := '';
      StringGrid1.Cells[7, 1] := '';
      UpdateStats;
      SaveListToFile;
      Exit;
    end;

    for i := 0 to TempList.Count - 1 do
    begin
      RIdx := i + 1;
      Cols := TempList[i].Split([',']);
      if Length(Cols) >= 7 then
      begin
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
  finally
    TempList.Free;
  end;
  SaveListToFile;
  UpdateStats;
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
begin
  if ARow = 0 then Exit;

  if gdSelected in State then
    StringGrid1.Canvas.Brush.Color := $003A3A3A
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
  else
  begin
    StringGrid1.Canvas.Font.Color := clWhite;
    StringGrid1.Canvas.Font.Style := [];
  end;

  StringGrid1.Canvas.TextRect(Rect, Rect.Left + 8, Rect.Top + 6, StringGrid1.Cells[ACol, ARow]);
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

procedure TForm1.StringGrid1MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ACol, ARow: Integer;
  i, j: Integer;
  TempRow: TArray<string>;
  Swapped: Boolean;
  Direction, Cmp: Integer;
  Va, Vb: Double;
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
    MenuConnectSoftEther.Enabled := HasRow;

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
        case ACol of
          1: Cmp := CompareIP(StringGrid1.Cells[ACol, i], StringGrid1.Cells[ACol, i + 1]);
          2, 4: Cmp := StrToIntDef(StringGrid1.Cells[ACol, i], 0) -
                       StrToIntDef(StringGrid1.Cells[ACol, i + 1], 0);
          5:
            begin
              Va := StrToFloatDef(StringGrid1.Cells[ACol, i], 0);
              Vb := StrToFloatDef(StringGrid1.Cells[ACol, i + 1], 0);
              if Va > Vb then Cmp := 1
              else if Va < Vb then Cmp := -1
              else Cmp := 0;
            end;
        else
          Cmp := AnsiCompareText(StringGrid1.Cells[ACol, i], StringGrid1.Cells[ACol, i + 1]);
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

// Показывает текст в третьей панели статус-бара (статус SoftEther-подключения)
procedure TForm1.SetVpnStatusText(const S: string);
begin
  if StatusBar1.Panels.Count > 2 then
    StatusBar1.Panels[2].Text := S;
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
  CacheFile, Candidate: string;
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

procedure TForm1.MenuConnectSoftEtherClick(Sender: TObject);
var
  IP: string;
begin
  if (FContextRow <= 0) or (FContextRow >= StringGrid1.RowCount) then Exit;
  IP := Trim(StringGrid1.Cells[1, FContextRow]);
  if IP = '' then Exit;

  if FVpnCmdPath = '' then
    FVpnCmdPath := LocateVpnCmd;
  if FVpnCmdPath = '' then
  begin
    ShowMessage('Без vpncmd.exe автоматическое подключение через SoftEther недоступно.');
    Exit;
  end;

  // Порт 1443/443 — стандартный порт нативного протокола SoftEther у
  // публичных узлов VPN Gate (не тот "Порт", что в таблице — тот для OpenVPN)
  TSoftEtherThread.Create(Self, seaConnect, IP, 443);
end;

procedure TForm1.MenuDisconnectSoftEtherClick(Sender: TObject);
begin
  if FVpnCmdPath = '' then
    FVpnCmdPath := LocateVpnCmd;
  if FVpnCmdPath = '' then Exit;
  TSoftEtherThread.Create(Self, seaDisconnect, '', 0);
end;

procedure TForm1.NetHTTPClient1ValidateServerCertificate(const Sender: TObject;
  const ARequest: TURLRequest; const Certificate: TCertificate;
  var Accepted: Boolean);
begin
  Accepted := True;
end;

procedure TForm1.SaveListToFile;
var
  SL: TStringList;
  i: Integer;
begin
  SL := TStringList.Create;
  try
    for i := 1 to StringGrid1.RowCount - 1 do
    begin
      if Trim(StringGrid1.Cells[1, i]) <> '' then
      begin
        SL.Add(StringGrid1.Cells[1, i] + ',' + // IP
               StringGrid1.Cells[2, i] + ',' + // Порт
               StringGrid1.Cells[3, i] + ',' + // Страна
               StringGrid1.Cells[4, i] + ',' + // Пинг
               StringGrid1.Cells[5, i] + ',' + // Скорость
               StringGrid1.Cells[6, i] + ',' + // Протокол
               StringGrid1.Cells[7, i]);       // Статус
      end;
    end;
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'servers.txt');
  finally
    SL.Free;
  end;
end;

{ TUpdateThread }

constructor TUpdateThread.Create(AForm: TForm1);
begin
  FForm := AForm;
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
  Cols: TArray<string>;
  RowIdx: Integer;
begin
  // Возвращаем кнопку на место и скрываем прогресс-бар
  FForm.ProgressBar1.Visible := False;
  FForm.Button1.Visible := True;

  if not FSuccess then
  begin
    ShowMessage('Ошибка скачивания: ' + FErrorMessage);
    Exit;
  end;

  if FTempServers.Count > 0 then
    FForm.StringGrid1.RowCount := FTempServers.Count + 1
  else
    FForm.StringGrid1.RowCount := 2;

  for i := 0 to FTempServers.Count - 1 do
  begin
    RowIdx := i + 1;
    Cols := FTempServers[i].Split([',']);
    if Length(Cols) >= 7 then
    begin
      FForm.StringGrid1.Cells[0, RowIdx] := IntToStr(RowIdx); // №
      FForm.StringGrid1.Cells[1, RowIdx] := Cols[0];          // IP
      FForm.StringGrid1.Cells[2, RowIdx] := Cols[1];          // Порт
      FForm.StringGrid1.Cells[3, RowIdx] := Cols[2];          // Страна
      FForm.StringGrid1.Cells[4, RowIdx] := Cols[3];          // Пинг
      FForm.StringGrid1.Cells[5, RowIdx] := Cols[4];          // Скорость
      FForm.StringGrid1.Cells[6, RowIdx] := Cols[5];          // Протокол
      FForm.StringGrid1.Cells[7, RowIdx] := Cols[6];          // Статус
    end;
  end;

  // Передаем свежесобранный словарь .ovpn-конфигов форме (используется контекстным
  // меню «Сохранить .ovpn файл») и освобождаем предыдущий
  FreeAndNil(FForm.FOvpnConfigs);
  FForm.FOvpnConfigs := FTempOvpn;
  FTempOvpn := nil;

  // Свежий список ещё не отсортирован — сбрасываем стрелку в шапке таблицы
  FForm.FSortColumn := -1;
  FForm.UpdateSortHeaders;

  FForm.SaveListToFile;
  FForm.UpdateStats;
end;

end.
