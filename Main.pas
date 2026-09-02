unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, IdBaseComponent, IdComponent,
  IdTCPConnection, IdTCPClient, IdHTTP, Vcl.Grids, Vcl.StdCtrls, Vcl.ExtCtrls,
  Clipbrd, System.NetEncoding,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent,
  Vcl.ComCtrls, System.ImageList, Vcl.ImgList, Vcl.Menus,
  System.Generics.Collections, System.Generics.Defaults, System.IOUtils;

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
    SaveDialog1: TSaveDialog;
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
    procedure StringGrid1MouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure StringGrid1ContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure MenuCopyIPClick(Sender: TObject);
    procedure MenuCopyPortClick(Sender: TObject);
    procedure MenuRecheckServerClick(Sender: TObject);
    procedure MenuSaveOvpnClick(Sender: TObject);
  private
    FOvpnConfigs: TDictionary<string, string>; // IP -> декодированный .ovpn (заполняется при обновлении списка)
    FContextRow: Integer;                      // Строка, по которой кликнули правой кнопкой
    FSortColumn: Integer;                      // Текущая колонка сортировки (-1 — нет)
    FSortAscending: Boolean;                   // Направление текущей сортировки
    procedure SaveListToFile;
    procedure UpdateStats;
    procedure UpdateSortHeaders;
    procedure SortGridByColumn(ACol: Integer);
    procedure SaveOvpnForRow(ARow: Integer);
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

const
  // Базовые (без стрелки сортировки) подписи сортируемых колонок
  ColHeaderBase: array[0..2] of string = ('IP', 'Порт', 'Страна');

type
  TServerRow = record
    Cells: array[0..3] of string;
  end;

// Сравнение IP-адресов по числовым октетам, а не как обычных строк
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
  // Безопасно обновляем статус в нужной строке таблицы из главного потока
  if FRowIndex < FForm.StringGrid1.RowCount then
    FForm.StringGrid1.Cells[3, FRowIndex] := FStatus;
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
    TCPClient.Free;
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
  StringGrid1.ColCount := 4;
  StringGrid1.FixedRows := 1;
  StringGrid1.RowCount := 2; // Минимум 2 строки (шапка + 1 пустая)

  FOvpnConfigs := TDictionary<string, string>.Create;
  FContextRow := -1;
  FSortColumn := -1;
  FSortAscending := True;

  // Заголовки колонок (по IP/Порту/Стране можно сортировать кликом по шапке)
  UpdateSortHeaders;
  StringGrid1.Cells[3, 0] := 'Статус';

  StringGrid1.ColWidths[0] := 160;
  StringGrid1.ColWidths[1] := 80;
  StringGrid1.ColWidths[2] := 90;
  StringGrid1.ColWidths[3] := 200;

  StringGrid1.DoubleBuffered := True;
  StringGrid1.Options := StringGrid1.Options + [goRowSelect];
  StringGrid1.Options := StringGrid1.Options - [goEditing];
  StringGrid1.PopupMenu := PopupMenu1;

  SaveDialog1.DefaultExt := 'ovpn';
  SaveDialog1.Filter := 'Конфигурация OpenVPN (*.ovpn)|*.ovpn|Все файлы (*.*)|*.*';

  FilePath := ExtractFilePath(ParamStr(0)) + 'servers.txt';
  if not FileExists(FilePath) then Exit;

  SL := TStringList.Create;
  Columns := TStringList.Create;
  Columns.StrictDelimiter := True;
  Columns.Delimiter := ',';

  try
    SL.LoadFromFile(FilePath);
    if SL.Count > 0 then
      StringGrid1.RowCount := SL.Count + 1; // Устанавливаем точный размер под файл

    RowIdx := 0;
    for i := 0 to SL.Count - 1 do
    begin
      if Trim(SL[i]) = '' then Continue;
      Columns.DelimitedText := SL[i];
      if Columns.Count >= 4 then
      begin
        Inc(RowIdx);
        StringGrid1.Cells[0, RowIdx] := Columns[0];
        StringGrid1.Cells[1, RowIdx] := Columns[1];
        StringGrid1.Cells[2, RowIdx] := Columns[2];
        StringGrid1.Cells[3, RowIdx] := Columns[3];
      end;
    end;

    // Если реальных строк оказалось меньше
    if RowIdx > 0 then
      StringGrid1.RowCount := RowIdx + 1;
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
  // Автоматически растягиваем последнюю колонку (Статус) по ширине окна
  if Assigned(StringGrid1) and (StringGrid1.ColCount = 4) then
  begin
    TotalWidth := StringGrid1.ClientWidth - StringGrid1.ColWidths[0] -
                  StringGrid1.ColWidths[1] - StringGrid1.ColWidths[2] - 10;
    if TotalWidth > 150 then
      StringGrid1.ColWidths[3] := TotalWidth;
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
    StringGrid1.Cells[3, i] := 'Проверка...';
    TTCPCheckThread.Create(Self, i, StringGrid1.Cells[0, i], StrToIntDef(StringGrid1.Cells[1, i], 443));
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
      if StringGrid1.Cells[3, i] = 'Работает!' then
      begin
        TempList.Add(StringGrid1.Cells[0, i] + ',' +
                     StringGrid1.Cells[1, i] + ',' +
                     StringGrid1.Cells[2, i] + ',' +
                     StringGrid1.Cells[3, i]);
      end;
    end;

    // Безопасный размер: если рабочих нет, оставляем 2 строки (пустую), чтобы не вызвать ошибку
    if TempList.Count > 0 then
      StringGrid1.RowCount := TempList.Count + 1
    else
    begin
      StringGrid1.RowCount := 2;
      StringGrid1.Cells[0, 1] := '';
      StringGrid1.Cells[1, 1] := '';
      StringGrid1.Cells[2, 1] := '';
      StringGrid1.Cells[3, 1] := '';
      Exit;
    end;

    for i := 0 to TempList.Count - 1 do
    begin
      RIdx := i + 1;
      Cols := TempList[i].Split([',']);
      if Length(Cols) >= 4 then
      begin
        StringGrid1.Cells[0, RIdx] := Cols[0];
        StringGrid1.Cells[1, RIdx] := Cols[1];
        StringGrid1.Cells[2, RIdx] := Cols[2];
        StringGrid1.Cells[3, RIdx] := Cols[3];
      end;
    end;
  finally
    TempList.Free;
  end;
  SaveListToFile;
  UpdateStats;
end;

procedure TForm1.StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer;
  Rect: TRect; State: TGridDrawState);
begin
  // Шапку таблицы не трогаем — оставляем под стиль
  if ARow = 0 then Exit;

  // Окрашиваем фон строк (эффект «зебры» и подсветка выделенной строки)
  if gdSelected in State then
    StringGrid1.Canvas.Brush.Color := $003A3A3A // Цвет активной строки
  else if ARow mod 2 = 0 then
    StringGrid1.Canvas.Brush.Color := $00252525 // Четная строка (чуть светлее)
  else
    StringGrid1.Canvas.Brush.Color := $001E1E1E; // Нечетная строка (основной фон)

  StringGrid1.Canvas.FillRect(Rect);

  // Настройка цвета текста для разных колонок и статусов
  if ACol = 3 then
  begin
    if StringGrid1.Cells[ACol, ARow] = 'Работает!' then
      StringGrid1.Canvas.Font.Color := $0066CC33 // Зеленый
    else if StringGrid1.Cells[ACol, ARow] = 'Недоступен' then
      StringGrid1.Canvas.Font.Color := $005555FF // Красный
    else if StringGrid1.Cells[ACol, ARow] = 'Проверка...' then
      StringGrid1.Canvas.Font.Color := $0033CCFF // Голубой
    else
      StringGrid1.Canvas.Font.Color := clSilver;
    StringGrid1.Canvas.Font.Style := [fsBold];
  end
  else
  begin
    StringGrid1.Canvas.Font.Color := clWhite;
    StringGrid1.Canvas.Font.Style := [];
  end;

  // Выводим текст с небольшим отступом от границ ячейки
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
    if Trim(StringGrid1.Cells[0, i]) <> '' then
    begin
      Inc(Total);
      if StringGrid1.Cells[3, i] = 'Работает!' then
        Inc(Working);
    end;
  end;

  StatusBar1.Panels[0].Text := 'Всего серверов: ' + IntToStr(Total);
  StatusBar1.Panels[1].Text := 'Работает: ' + IntToStr(Working);
end;

// Отображает в шапке таблицы стрелку (вверх/вниз), указывающую текущую колонку и
// направление сортировки. Символы стрелок заданы кодами (#9650/#9660), чтобы
// не зависеть от кодировки исходного файла.
procedure TForm1.UpdateSortHeaders;
var
  c: Integer;
begin
  for c := 0 to 2 do
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

// Сортирует строки таблицы по колонке ACol (0 — IP, 1 — Порт, 2 — Страна).
// Повторный клик по той же колонке меняет направление сортировки.
procedure TForm1.SortGridByColumn(ACol: Integer);
var
  Rows: TArray<TServerRow>;
  RowCount, i, c, Direction: Integer;
  ColToSort: Integer;
  Comparer: TComparison<TServerRow>;
begin
  RowCount := StringGrid1.RowCount - 1; // без учета шапки
  if RowCount <= 1 then Exit;
  if (RowCount = 1) and (Trim(StringGrid1.Cells[0, 1]) = '') then Exit;

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
  ColToSort := ACol;

  SetLength(Rows, RowCount);
  for i := 0 to RowCount - 1 do
    for c := 0 to 3 do
      Rows[i].Cells[c] := StringGrid1.Cells[c, i + 1];

  Comparer :=
    function(const A, B: TServerRow): Integer
    begin
      case ColToSort of
        0: Result := CompareIP(A.Cells[0], B.Cells[0]);
        1: Result := StrToIntDef(A.Cells[1], 0) - StrToIntDef(B.Cells[1], 0);
      else
        Result := CompareText(A.Cells[2], B.Cells[2]);
      end;
      Result := Result * Direction;
    end;

  TArray.Sort<TServerRow>(Rows, TComparer<TServerRow>.Construct(Comparer));

  for i := 0 to RowCount - 1 do
    for c := 0 to 3 do
      StringGrid1.Cells[c, i + 1] := Rows[i].Cells[c];

  UpdateSortHeaders;
end;

procedure TForm1.StringGrid1MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  ACol, ARow: Integer;
  IP: string;
begin
  if Button <> mbLeft then Exit;

  StringGrid1.MouseToCell(X, Y, ACol, ARow);

  // Клик по шапке — сортировка по колонке (IP/Порт/Страна)
  if ARow = 0 then
  begin
    if ACol in [0, 1, 2] then
      SortGridByColumn(ACol);
    Exit;
  end;

  // Клик по строке данных — быстрое копирование IP в буфер обмена
  if (ARow > 0) and (ARow < StringGrid1.RowCount) then
  begin
    IP := Trim(StringGrid1.Cells[0, ARow]);
    if IP <> '' then
    begin
      Clipboard.AsText := IP;
      ShowMessage('Адрес ' + IP + ' скопирован в буфер обмена!');
    end;
  end;
end;

// Определяет строку под курсором перед показом контекстного меню (ПКМ) и
// отменяет показ меню, если клик пришелся на шапку или пустую область.
procedure TForm1.StringGrid1ContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  ACol, ARow: Integer;
  HasRow: Boolean;
begin
  StringGrid1.MouseToCell(MousePos.X, MousePos.Y, ACol, ARow);

  if (ARow <= 0) or (ARow >= StringGrid1.RowCount) then
  begin
    Handled := True; // не показываем меню вне строк с данными
    Exit;
  end;

  StringGrid1.Row := ARow;
  FContextRow := ARow;

  HasRow := Trim(StringGrid1.Cells[0, ARow]) <> '';
  MenuCopyIP.Enabled := HasRow;
  MenuCopyPort.Enabled := HasRow;
  MenuRecheckServer.Enabled := HasRow;
  MenuSaveOvpn.Enabled := HasRow;
end;

procedure TForm1.MenuCopyIPClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) then
    Clipboard.AsText := StringGrid1.Cells[0, FContextRow];
end;

procedure TForm1.MenuCopyPortClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) then
    Clipboard.AsText := StringGrid1.Cells[1, FContextRow];
end;

procedure TForm1.MenuRecheckServerClick(Sender: TObject);
begin
  if (FContextRow > 0) and (FContextRow < StringGrid1.RowCount) and
     (Trim(StringGrid1.Cells[0, FContextRow]) <> '') then
  begin
    StringGrid1.Cells[3, FContextRow] := 'Проверка...';
    TTCPCheckThread.Create(Self, FContextRow, StringGrid1.Cells[0, FContextRow],
      StrToIntDef(StringGrid1.Cells[1, FContextRow], 443));
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

  IP := Trim(StringGrid1.Cells[0, ARow]);
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
      SL.Add(StringGrid1.Cells[0, i] + ',' +
             StringGrid1.Cells[1, i] + ',' +
             StringGrid1.Cells[2, i] + ',' +
             StringGrid1.Cells[3, i]);
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
  inherited Create(False); // Запускаем поток сразу
  FreeOnTerminate := True; // Автоудаление после завершения
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
  CSVData, OVPN, PortStr, CountryStr: string;
  Lines, Columns, OVPNLines: TStringList;
  i, j, P: Integer;
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
          OVPN := '';
          try
            OVPN := TNetEncoding.Base64.Decode(Columns[14]);
            OVPNLines.Text := OVPN;

            for j := 0 to OVPNLines.Count - 1 do
            begin
              if Pos('remote ', Trim(OVPNLines[j])) = 1 then
              begin
                PortStr := Trim(OVPNLines[j]);
                Delete(PortStr, 1, 7);
                PortStr := Trim(PortStr);
                P := Pos(' ', PortStr);
                if P > 0 then
                begin
                  Delete(PortStr, 1, P);
                  PortStr := Trim(PortStr);
                  Break;
                end;
              end;
            end;
          except
          end;

          // CountryShort (двухбуквенный код страны) из CSV VPN Gate
          CountryStr := Trim(Columns[6]);
          if CountryStr = '' then
            CountryStr := '??';

          FTempServers.Add(Columns[1] + ',' + PortStr + ',' + CountryStr + ',Ожидание');

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
  // Скрываем прогресс-бар и возвращаем кнопку на место
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
    if Length(Cols) >= 4 then
    begin
      FForm.StringGrid1.Cells[0, RowIdx] := Cols[0];
      FForm.StringGrid1.Cells[1, RowIdx] := Cols[1];
      FForm.StringGrid1.Cells[2, RowIdx] := Cols[2];
      FForm.StringGrid1.Cells[3, RowIdx] := Cols[3];
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
