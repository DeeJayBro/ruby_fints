require 'test_helper'

# Tests for CAMT-based statement retrieval (HKCAZ/HICAZ), which replaced the
# MT940 (HKKAZ) path.
class StatementTest < Minitest::Test
  class ScriptedConnection
    attr_reader :sent

    def initialize(responses)
      @responses = responses.dup
      @sent = []
    end

    def send_msg(msg)
      @sent << msg.to_s
      raise 'no scripted response left' if @responses.empty?
      @responses.shift
    end
  end

  DESCRIPTOR = 'urn:iso:std:iso:20022:tech:xsd:camt.052.001.02'.freeze

  # Minimal single-entry camt.052 document (no apostrophes, so the FinTS segment
  # framing survives being embedded as an @len@ binary).
  CAMT = <<~XML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.052.001.02">
      <BkToCstmrAcctRpt><Rpt>
        <Ntry>
          <Amt Ccy="EUR">42.00</Amt>
          <CdtDbtInd>CRDT</CdtDbtInd>
          <Sts>BOOK</Sts>
          <BookgDt><Dt>2023-03-01</Dt></BookgDt>
          <ValDt><Dt>2023-03-01</Dt></ValDt>
          <BkTxCd><Prtry><Cd>166</Cd></Prtry></BkTxCd>
          <NtryDtls><TxDtls>
            <RltdPties><Dbtr><Nm>ACME GmbH</Nm></Dbtr>
              <DbtrAcct><Id><IBAN>DE02120300000000202051</IBAN></Id></DbtrAcct></RltdPties>
            <RmtInf><Ustrd>Invoice 42</Ustrd></RmtInf>
          </TxDtls></NtryDtls>
        </Ntry>
      </Rpt></BkToCstmrAcctRpt>
    </Document>
  XML

  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  def account
    {
      iban: 'DE12345678901234567890',
      bic: 'ABCDEFGH1DEF',
      accountnumber: '123456',
      subaccount: nil,
      blz: '778000111'
    }
  end

  def hicaz_segment(camt)
    escaped = FinTS::Helper.fints_escape(DESCRIPTOR)
    "HICAZ:3:1:4+#{escaped}+@#{camt.bytesize}@#{camt}"
  end

  def build_client(conn)
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints', poll_interval: 0)
    client.instance_variable_set(:@connection, conn)
    client.instance_variable_set(:@system_id, 'SYS123')
    client.instance_variable_set(:@bpd, {
      system_id: 'SYS123',
      hkcazversion: 1,
      camt_descriptors: [DESCRIPTOR],
      tan_mechs: [],
      tan_methods: [],
      tan_requirements: {},
      holdings_supported: false
    })
    client
  end

  def build_dialog
    FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
  end

  # --- request building ------------------------------------------------------

  def test_create_statement_message_builds_escaped_hkcaz
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    dialog = build_dialog
    dialog.hkcazversion = 1
    dialog.camt_descriptors = [DESCRIPTOR]

    msg = client.create_statement_message(dialog, account, Date.new(2023, 1, 1), Date.new(2023, 1, 31), nil).to_s
    # CAMT identifies the account by IBAN:BIC only (no national tail), otherwise
    # some banks reject with "3010 Kontonummer ist ungültig".
    assert_includes msg,
                    'HKCAZ:3:1+DE12345678901234567890:ABCDEFGH1DEF' \
                    '+urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.02+N+20230101+20230131++'
  end

  def test_sepa_account_identifier_is_iban_and_bic_only
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    assert_equal 'DE12345678901234567890:ABCDEFGH1DEF', client.sepa_account_identifier(account)
  end

  def test_continuation_message_carries_touchdown_and_no_hktan
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    dialog = build_dialog
    dialog.hkcazversion = 1
    dialog.camt_descriptors = [DESCRIPTOR]

    msg = client.create_statement_message(dialog, account, Date.new(2023, 1, 1), Date.new(2023, 1, 31), 'TD99').to_s
    assert_includes msg, '+TD99'
    refute_includes msg, 'HKTAN'
  end

  # --- end-to-end ------------------------------------------------------------

  def test_get_statement_returns_camt_transactions
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    statement_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'" +
                     hicaz_segment(CAMT) + "'HNHBS:4:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:2:1+3'"

    conn = ScriptedConnection.new([init_resp, statement_resp, end_resp])
    client = build_client(conn)

    txs = client.get_statement(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2))

    assert_equal 1, txs.length
    tx = txs.first
    assert_in_delta 42.0, tx[:amount], 0.001
    assert_equal 'ACME GmbH', tx[:name]
    assert_equal 'Invoice 42', tx[:purpose]
    assert_equal Date.new(2023, 3, 1), tx[:booking_date]
    # full CAMT metadata survives the HKCAZ -> HICAZ -> parse pipeline
    assert_equal({ '@Ccy' => 'EUR', '#text' => '42.00' }, tx[:raw]['Amt'])

    # the order was requested via HKCAZ, not HKKAZ
    assert(conn.sent.any? { |m| m.include?('HKCAZ:3:1') }, 'expected an HKCAZ order')
    refute(conn.sent.any? { |m| m.include?('HKKAZ') }, 'must not send HKKAZ any more')
  end

  def test_get_statement_repairs_transport_double_encoded_utf8
    # The transport decodes the whole response as ISO-8859-1 then re-encodes to
    # UTF-8; the CAMT XML is itself UTF-8, so "München" reaches us double-encoded
    # as "MÃ¼nchen". get_statement must repair it back to "München".
    mangled = 'München'.encode('utf-8').b.force_encoding('iso-8859-1').encode('utf-8')
    refute_equal 'München', mangled, 'sanity: the name really is corrupted on the wire'

    camt = CAMT.sub('ACME GmbH', mangled)
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    statement_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'" +
                     hicaz_segment(camt) + "'HNHBS:4:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:2:1+3'"

    conn = ScriptedConnection.new([init_resp, statement_resp, end_resp])
    client = build_client(conn)

    tx = client.get_statement(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2)).first
    assert_equal 'München', tx[:name]
  end

  def test_repair_camt_encoding_reverses_double_encoding
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    mangled = 'Zürich Straße'.encode('utf-8').b.force_encoding('iso-8859-1').encode('utf-8')
    assert_equal 'Zürich Straße', client.repair_camt_encoding(mangled)
  end

  def test_repair_camt_encoding_leaves_genuine_latin1_derived_text_untouched
    # "Köln" is correct UTF-8 whose byte-reversal is invalid UTF-8, i.e. what you
    # get when the transport already decoded ISO-8859-1 CAMT correctly. It must
    # not be "repaired" (which would corrupt it).
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    assert_equal 'Köln', client.repair_camt_encoding('Köln')
  end

  def test_get_transactions_is_an_alias_for_get_statement
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    statement_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'" +
                     hicaz_segment(CAMT) + "'HNHBS:4:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:2:1+3'"

    conn = ScriptedConnection.new([init_resp, statement_resp, end_resp])
    client = build_client(conn)

    txs = client.get_transactions(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2))
    assert_equal 1, txs.length
    assert_in_delta 42.0, txs.first[:amount], 0.001
  end

  def test_get_statement_paginates_over_touchdown
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    # first statement response asks us to continue (HIRMS 3040 for the HKCAZ order)
    page1 = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'" \
            "HIRMS:3:2:3+3040::mehr:TD-NEXT'" +
            hicaz_segment(CAMT) + "'HNHBS:5:1+2'"
    page2 = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'" +
            hicaz_segment(CAMT) + "'HNHBS:4:1+3'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+4'HIRMG:2:2+0010::ok'HNHBS:2:1+4'"

    conn = ScriptedConnection.new([init_resp, page1, page2, end_resp])
    client = build_client(conn)

    txs = client.get_statement(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2))

    # one entry from each page
    assert_equal 2, txs.length
    # the continuation request echoed the touchdown point
    assert(conn.sent.any? { |m| m.include?('+TD-NEXT') }, 'expected a continuation carrying the touchdown')
  end

  def test_feedback_messages_surface_segment_rejection
    # the codes a bank returns for a rejected HKCAZ order
    data = "HNHBK:1:3+000000000100+300+DLG1+2'" \
           "HIRMG:3:2+3060::Bitte beachten Sie die enthaltenen Warnungen/Hinweise.+3905::Bitte senden Sie die Anfrage erneut.'" \
           "HIRMS:4:2:3+3010::Kontonummer ist ungueltig. Bitte Eingabe ueberpruefen.'" \
           "HNHBS:5:1+2'"
    msgs = FinTS::Response.new(data).feedback_messages
    assert_includes msgs, '3060: Bitte beachten Sie die enthaltenen Warnungen/Hinweise.'
    assert_includes msgs, '3905: Bitte senden Sie die Anfrage erneut.'
    assert_includes msgs, '3010: Kontonummer ist ungueltig. Bitte Eingabe ueberpruefen.'
  end

  def test_get_statement_degrades_to_empty_on_segment_rejection
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    # order accepted at message level (3xxx warnings) but rejected per-segment
    rejected = "HNHBK:1:3+000000000100+300+DLG1+2'" \
               "HIRMG:2:2+3060::Warnung'" \
               "HIRMS:3:2:3+3010::Kontonummer ist ungueltig'HNHBS:4:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:2:1+3'"

    conn = ScriptedConnection.new([init_resp, rejected, end_resp])
    client = build_client(conn)

    # must not raise (HIRMG is warning-level), just come back empty
    txs = client.get_statement(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2))
    assert_empty txs
  end

  def test_get_statement_raises_when_bank_has_no_camt_support
    init_resp = "HNHBK:1:3+000000000100+300+DLG1+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:2:1+3'"

    conn = ScriptedConnection.new([init_resp, end_resp])
    client = build_client(conn)
    # bank did not advertise any camt descriptor
    client.instance_variable_get(:@bpd)[:camt_descriptors] = []

    assert_raises FinTS::SegmentNotFoundError do
      client.get_statement(account, Date.new(2023, 3, 1), Date.new(2023, 3, 2))
    end
  end
end
