require 'test_helper'

class HoldingsTest < Minitest::Test
  # A realistic MT535 "statement of holdings" payload as delivered inside a
  # HIWPD segment. Two financial instruments, wrapped in a GENL block and
  # terminated with the MT535 end marker '-'.
  MT535_LINES = [
    ':16R:GENL',
    ':28E:1/ONLY',
    ':13A::STAT//086',
    ':20C::SEME//NONREF',
    ':98A::PREP//20170428',
    ':98C::STAT//20170427193600',
    ':22H::STTY//OFFS',
    ':97A::SAFE//1234567890',
    ':17B::ALLL//Y',
    ':16S:GENL',
    ':16R:FIN',
    ':35B:ISIN LU0635178014',
    '/DE/ETF127',
    'COMS.-MSCI EM.M.T.U.ETF I',
    ':90B::MRKT//ACTU/EUR38,82',
    ':98A::PRIC//20170428',
    ':93B::AGGR//UNIT/16,8211',
    ':19A::HOLD//EUR970,17',
    ':70E::HOLD//1STK',
    ':16S:FIN',
    ':16R:FIN',
    ':35B:ISIN DE0008474248',
    '/DE/847424',
    'DEKA-EUROPAPOTENTIAL CF',
    ':90B::MRKT//ACTU/EUR154,80',
    ':98A::PRIC//20170428',
    ':93B::AGGR//UNIT/3,7315',
    ':19A::HOLD//EUR577,64',
    ':16S:FIN'
  ].freeze

  def mt535_payload
    MT535_LINES.join("\r\n") + "\r\n-"
  end

  def test_mt535_miniparser_extracts_all_instruments
    holdings = FinTS::MT535Miniparser.new.parse(mt535_payload.split("\r\n"))

    assert_equal 2, holdings.length

    first = holdings[0]
    assert_equal 'LU0635178014', first[:ISIN]
    assert_equal 'ETF127', first[:WKN]
    assert_equal 'COMS.-MSCI EM.M.T.U.ETF I', first[:name]
    assert_equal 38.82, first[:market_value]
    assert_equal 'EUR', first[:value_symbol]
    assert_equal Date.new(2017, 4, 28), first[:valuation_date]
    assert_equal 16.8211, first[:pieces]
    assert_equal 970.17, first[:total_value]

    second = holdings[1]
    assert_equal 'DE0008474248', second[:ISIN]
    assert_equal '847424', second[:WKN]
    assert_equal 'DEKA-EUROPAPOTENTIAL CF', second[:name]
    assert_equal 154.8, second[:market_value]
    assert_equal 3.7315, second[:pieces]
    assert_equal 577.64, second[:total_value]
  end

  def test_mt535_miniparser_flushes_last_clause_without_terminator
    # Some banks omit the trailing '-' marker; the final instrument must still
    # be returned.
    lines = MT535_LINES # no trailing '-'
    holdings = FinTS::MT535Miniparser.new.parse(lines)
    assert_equal 2, holdings.length
    assert_equal 'DE0008474248', holdings[1][:ISIN]
  end

  def test_mt535_miniparser_returns_empty_for_no_instruments
    holdings = FinTS::MT535Miniparser.new.parse([':16R:GENL', ':16S:GENL', '-'])
    assert_empty holdings
  end

  def test_extract_mt535_lines_strips_header_marker_and_cr
    client = build_client
    segment = "HIWPD:3:6:4+@#{mt535_payload.bytesize}@#{mt535_payload}"
    lines = client.extract_mt535_lines(segment)

    assert_equal ':16R:GENL', lines.first
    assert_equal '-', lines.last
    refute(lines.any? { |l| l.include?("\r") }, 'carriage returns must be stripped')
    refute(lines.any?(&:empty?), 'empty lines must be dropped')
  end

  def test_holdings_from_response_parses_hiwpd_segment
    client = build_client
    resp = build_response_with_holdings(mt535_payload)

    holdings = client.holdings_from_response(resp)
    assert_equal 2, holdings.length
    assert_equal 'LU0635178014', holdings[0][:ISIN]
    assert_equal 'DE0008474248', holdings[1][:ISIN]
  end

  def test_holdings_from_response_without_hiwpd_returns_empty
    client = build_client
    resp = FinTS::Response.new("HNHBK:1:3+000000000100+300+42+1'HNHBS:2:1+42'")
    assert_empty client.holdings_from_response(resp)
  end

  def test_create_get_holdings_message_uses_national_format_for_v6
    client = build_client
    dialog = build_dialog
    dialog.hkwpdversion = 6

    msg = client.create_get_holdings_message(dialog, account_hash)
    assert_includes msg.to_s, 'HKWPD:3:6+123456::280:778000111'
  end

  def test_create_get_holdings_message_uses_sepa_format_for_v7
    client = build_client
    dialog = build_dialog
    dialog.hkwpdversion = 7

    msg = client.create_get_holdings_message(dialog, account_hash)
    assert_includes msg.to_s, 'HKWPD:3:7+DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111'
  end

  # Newer segment versions (8+) keep the international account identification.
  def test_account_identifier_uses_national_format_below_v7
    client = build_client
    (4..6).each do |v|
      assert_equal '123456::280:778000111', client.account_identifier(account_hash, v)
    end
  end

  def test_account_identifier_uses_international_format_from_v7
    client = build_client
    [7, 8].each do |v|
      assert_equal 'DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111',
                   client.account_identifier(account_hash, v)
    end
  end

  def test_create_balance_message_supports_v8
    client = build_client
    dialog = build_dialog
    dialog.hksalversion = 8

    msg = client.create_balance_message(dialog, account_hash)
    assert_includes msg.to_s, 'HKSAL:3:8+DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111+N'
  end

  def test_create_get_holdings_message_supports_v8
    client = build_client
    dialog = build_dialog
    dialog.hkwpdversion = 8

    msg = client.create_get_holdings_message(dialog, account_hash)
    assert_includes msg.to_s, 'HKWPD:3:8+DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111'
  end

  private

  def account_hash
    {
      iban: 'DE12345678901234567890',
      bic: 'ABCDEFGH1DEF',
      accountnumber: '123456',
      subaccount: nil,
      blz: '778000111'
    }
  end

  def build_client
    FinTS::Client.logger.level = Logger::ERROR
    FinTS::PinTanClient.new('778000111', 'user', 'pin', 'https://example.com/fints')
  end

  def build_dialog
    FinTS::Dialog.new('778000111', 'user', 'pin', 0, nil)
  end

  def build_response_with_holdings(payload)
    data = "HNHBK:1:3+000000000100+300+42+1'" \
           "HIRMG:2:2+0010::Nachricht entgegengenommen'" \
           "HIWPD:3:6:4+@#{payload.bytesize}@#{payload}'" \
           "HNHBS:4:1+42'"
    FinTS::Response.new(data)
  end
end
