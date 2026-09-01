object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'Form1'
  ClientHeight = 539
  ClientWidth = 994
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 15
  object Panel1: TPanel
    Left = 0
    Top = 0
    Width = 994
    Height = 89
    Align = alTop
    TabOrder = 0
    ExplicitWidth = 988
    object Button1: TButton
      Left = 512
      Top = 33
      Width = 145
      Height = 25
      Caption = #1054#1073#1085#1086#1074#1080#1090#1100
      TabOrder = 0
      OnClick = Button1Click
    end
    object Button2: TButton
      Left = 663
      Top = 33
      Width = 145
      Height = 25
      Caption = #1055#1088#1086#1074#1077#1088#1080#1090#1100' '#1089#1077#1088#1074#1077#1088#1099
      TabOrder = 1
      OnClick = Button2Click
    end
    object Button3: TButton
      Left = 814
      Top = 33
      Width = 155
      Height = 25
      Caption = #1054#1089#1090#1072#1074#1080#1090#1100' '#1090#1086#1083#1100#1082#1086' '#1088#1072#1073#1086#1095#1080#1077
      TabOrder = 2
      OnClick = Button3Click
    end
  end
  object ListView1: TListView
    Left = 0
    Top = 89
    Width = 994
    Height = 450
    Align = alClient
    Columns = <
      item
        Caption = 'IP'
        Width = 150
      end
      item
        Caption = #1055#1086#1088#1090
      end
      item
        Caption = #1055#1088#1086#1090#1086#1082#1086#1083
      end
      item
        Caption = #1057#1090#1072#1090#1091#1089
        Width = 150
      end>
    TabOrder = 1
    ViewStyle = vsReport
    OnDblClick = ListView1DblClick
    ExplicitLeft = 96
    ExplicitTop = 144
    ExplicitWidth = 250
    ExplicitHeight = 150
  end
  object NetHTTPClient1: TNetHTTPClient
    UserAgent = 'Embarcadero URI Client/1.0'
    OnValidateServerCertificate = NetHTTPClient1ValidateServerCertificate
    Left = 824
    Top = 264
  end
end
