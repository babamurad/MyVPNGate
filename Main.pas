unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, IdBaseComponent, IdComponent,
  IdTCPConnection, IdTCPClient, IdHTTP, Vcl.ComCtrls, Vcl.StdCtrls, Vcl.ExtCtrls,
  Clipbrd, System.NetEncoding,
  System.Net.URLClient, System.Net.HttpClient, System.Net.HttpClientComponent;

type
  // 1. Сначала полностью описываем наш поток
  TTCPCheckThread = class(TThread)
  private
    FListItem: TListItem;
    FIP: string;
    FPort: Integer;
    FStatus: string;
    procedure UpdateUI;
  protected
    procedure Execute; override;
  public
    constructor Create(AListItem: TListItem; AIP: string; APort: Integer);
  end;

  // 2. Затем полностью описываем форму
  TForm1 = class(TForm)
    Panel1: TPanel;
    Button1: TButton;
    ListView1: TListView;
    NetHTTPClient1: TNetHTTPClient;
    Button2: TButton;
    Button3: TButton;
    procedure Button1Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure ListView1DblClick(Sender: TObject);
    procedure NetHTTPClient1ValidateServerCertificate(const Sender: TObject;
      const ARequest: TURLRequest; const Certificate: TCertificate;
      var Accepted: Boolean);
    procedure FormCreate(Sender: TObject);
  private
    { Private declarations }
    procedure SaveListToFile;
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

procedure TForm1.Button1Click(Sender: TObject);
var
  CSVData, OVPN, PortStr: string;
  Lines, Columns, OVPNLines: TStringList;
  i, j, P: Integer;
  Item: TListItem;
begin
  ListView1.Items.BeginUpdate;
  try
    try
      NetHTTPClient1.UserAgent := 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36';
      CSVData := NetHTTPClient1.Get('https://www.vpngate.net/api/iphone/').ContentAsString();
    except
      on E: Exception do
      begin
        ShowMessage('Ошибка скачивания: ' + E.Message);
        Exit;
      end;
    end;

    Lines := TStringList.Create;
    Columns := TStringList.Create;
    OVPNLines := TStringList.Create; // Новый список для строк внутри конфига
    Columns.StrictDelimiter := True;
    Columns.Delimiter := ',';

    try
      Lines.Text := CSVData;
      ListView1.Items.Clear;

      for i := 0 to Lines.Count - 1 do
      begin
        // Пропускаем пустые строки и комментарии API
        if (Trim(Lines[i]) = '') or (Lines[i][1] = '*') then Continue;

        Columns.DelimitedText := Lines[i];

        // Пропускаем строку с заголовками самой таблицы
        if (Columns.Count > 1) and (Columns[1] = 'IP') then Continue;

        if Columns.Count > 14 then
        begin
          Item := ListView1.Items.Add;
          Item.Caption := Columns[1];

          PortStr := '443'; // Порт по умолчанию
          try
            // Расшифровываем конфиг
            OVPN := TNetEncoding.Base64.Decode(Columns[14]);
            OVPNLines.Text := OVPN; // Разбиваем его на удобные строки

            // Проходимся по каждой строчке конфига
            for j := 0 to OVPNLines.Count - 1 do
            begin
              // Ищем строку, которая строго начинается с "remote "
              if Pos('remote ', Trim(OVPNLines[j])) = 1 then
              begin
                PortStr := Trim(OVPNLines[j]); // Например: "remote 14.10.120.193 7551"
                Delete(PortStr, 1, 7);         // Удаляем "remote ", остается "14.10.120.193 7551"
                PortStr := Trim(PortStr);

                P := Pos(' ', PortStr);        // Ищем пробел после IP
                if P > 0 then
                begin
                  Delete(PortStr, 1, P);       // Удаляем IP, остается только порт
                  PortStr := Trim(PortStr);
                  Break; // Нашли правильный порт - выходим из цикла!
                end;
              end;
            end;
          except
          end;

          Item.SubItems.Add(PortStr);
          Item.SubItems.Add('TCP');
          Item.SubItems.Add('Ожидание');
        end;
      end;
    finally
      Lines.Free;
      Columns.Free;
      OVPNLines.Free;
    end;
  finally
    ListView1.Items.EndUpdate;
  end;
  SaveListToFile;
end;

{ TTCPCheckThread }

constructor TTCPCheckThread.Create(AListItem: TListItem; AIP: string; APort: Integer);
begin
  inherited Create(False); // Поток запускается сразу после создания
  FreeOnTerminate := True; // Поток сам удалит себя из памяти после работы
  FListItem := AListItem;
  FIP := AIP;
  FPort := APort;
end;

procedure TTCPCheckThread.UpdateUI;
begin
  // Просто обновляем статус, порт менять больше не нужно
  FListItem.SubItems[2] := FStatus;
end;

procedure TTCPCheckThread.Execute;
var
  TCPClient: TIdTCPClient;
begin
  TCPClient := TIdTCPClient.Create(nil);
  try
    TCPClient.Host := FIP;
    TCPClient.Port := FPort; // Берем тот самый точный порт из таблицы!
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

procedure TForm1.Button2Click(Sender: TObject);
var
  i: Integer;
  Item: TListItem;
begin
  // Пробегаемся по всем строкам в таблице
  for i := 0 to ListView1.Items.Count - 1 do
  begin
    Item := ListView1.Items[i];
    Item.SubItems[2] := 'Проверка...'; // Меняем статус

    // Запускаем для каждого сервера свой отдельный поток проверки
    // Item.Caption - это IP, Item.SubItems[0] - это Порт (443)
    TTCPCheckThread.Create(Item, Item.Caption, StrToIntDef(Item.SubItems[0], 443));
  end;
end;

procedure TForm1.Button3Click(Sender: TObject);
var
  i: Integer;
begin
  ListView1.Items.BeginUpdate;
  try
    // Важно: при удалении строк из списка всегда идем с конца в начало (downto),
    // чтобы индексы не сдвигались и программа не выдала ошибку
    for i := ListView1.Items.Count - 1 downto 0 do
    begin
      // Если статус НЕ равен "Работает!", удаляем эту строку
      if ListView1.Items[i].SubItems[2] <> 'Работает!' then
        ListView1.Items[i].Delete;
    end;
  finally
    ListView1.Items.EndUpdate;
  end;
  SaveListToFile;
end;

procedure TForm1.FormCreate(Sender: TObject);
var
  SL, Columns: TStringList;
  i: Integer;
  Item: TListItem;
  FilePath: string;
begin
  FilePath := ExtractFilePath(ParamStr(0)) + 'servers.txt';

  // Если файла еще нет (первый запуск) - просто ничего не делаем
  if not FileExists(FilePath) then Exit;

  SL := TStringList.Create;
  Columns := TStringList.Create;
  Columns.StrictDelimiter := True;
  Columns.Delimiter := ',';

  ListView1.Items.BeginUpdate;
  try
    SL.LoadFromFile(FilePath);
    for i := 0 to SL.Count - 1 do
    begin
      if Trim(SL[i]) = '' then Continue;
      Columns.DelimitedText := SL[i];
      if Columns.Count >= 4 then
      begin
        Item := ListView1.Items.Add;
        Item.Caption := Columns[0];
        Item.SubItems.Add(Columns[1]);
        Item.SubItems.Add(Columns[2]);
        Item.SubItems.Add(Columns[3]);
      end;
    end;
  finally
    SL.Free;
    Columns.Free;
    ListView1.Items.EndUpdate;
  end;
end;

procedure TForm1.ListView1DblClick(Sender: TObject);
var
  IP, Port, FullAddress: string;
begin
  // Проверяем, что пользователь действительно выделил строку
  if ListView1.Selected <> nil then
  begin
    IP := ListView1.Selected.Caption;         // Берем IP (первая колонка)
    Port := ListView1.Selected.SubItems[0];   // Берем Порт (вторая колонка)

    FullAddress := IP; // + ':' + Port;           // Соединяем их через двоеточие

    // Копируем готовый результат в буфер обмена
    Clipboard.AsText := FullAddress;
    ShowMessage('Адрес ' + FullAddress + ' скопирован в буфер обмена!');
  end;
end;

procedure TForm1.NetHTTPClient1ValidateServerCertificate(const Sender: TObject;
  const ARequest: TURLRequest; const Certificate: TCertificate;
  var Accepted: Boolean);
begin
// Разрешаем любые сертификаты (игнорируем вмешательство провайдера)
  Accepted := True;
end;

procedure TForm1.SaveListToFile;
var
  SL: TStringList;
  i: Integer;
  Item: TListItem;
begin
  SL := TStringList.Create;
  try
    for i := 0 to ListView1.Items.Count - 1 do
    begin
      Item := ListView1.Items[i];
      SL.Add(Item.Caption + ',' + Item.SubItems[0] + ',' + Item.SubItems[1] + ',' + Item.SubItems[2]);
    end;
    SL.SaveToFile(ExtractFilePath(ParamStr(0)) + 'servers.txt');
  finally
    SL.Free;
  end;
end;

end.
