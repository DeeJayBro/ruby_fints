require 'test_helper'

# Unit tests for the camt.052/053 mini-parser that replaced the MT940 (cmxl)
# parsing of account transactions.
class CamtParserTest < Minitest::Test
  # A realistic camt.052.001.02 document with one incoming (CRDT) and one
  # outgoing (DBIT / SEPA direct debit) booked entry, carrying the kind of rich
  # metadata CAMT exposes: references, mandate/creditor ids, agent BICs, amount
  # details (currency exchange), charges and additional info. The first entry
  # also carries BOTH parties so the parser has to pick the debtor (the other
  # side of an incoming payment).
  CAMT052 = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.052.001.02">
      <BkToCstmrAcctRpt>
        <GrpHdr><MsgId>MSG-1</MsgId><CreDtTm>2023-01-16T09:00:00</CreDtTm></GrpHdr>
        <Rpt>
          <Id>RPT-1</Id>
          <Acct><Id><IBAN>DE12345678901234567890</IBAN></Id></Acct>
          <Ntry>
            <Amt Ccy="EUR">96.38</Amt>
            <CdtDbtInd>CRDT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2023-01-15</Dt></BookgDt>
            <ValDt><Dt>2023-01-15</Dt></ValDt>
            <AcctSvcrRef>ASR-ENTRY-1</AcctSvcrRef>
            <BkTxCd><Domn><Cd>PMNT</Cd></Domn><Prtry><Cd>166</Cd></Prtry></BkTxCd>
            <NtryDtls><TxDtls>
              <Refs><EndToEndId>E2E-STRIPE</EndToEndId></Refs>
              <AmtDtls><InstdAmt Ccy="USD">100.00</InstdAmt></AmtDtls>
              <RltdPties>
                <Dbtr><Nm>Stripe Payments UK Ltd</Nm></Dbtr>
                <DbtrAcct><Id><IBAN>DK6689000000010241</IBAN></Id></DbtrAcct>
                <Cdtr><Nm>Max Mustermann</Nm></Cdtr>
                <CdtrAcct><Id><IBAN>DE12345678901234567890</IBAN></Id></CdtrAcct>
              </RltdPties>
              <RltdAgts><DbtrAgt><FinInstnId><BIC>PBNKDEFFXXX</BIC></FinInstnId></DbtrAgt></RltdAgts>
              <RmtInf><Ustrd>STRIPEX4J1J3</Ustrd></RmtInf>
              <AddtlTxInf>SEPA GUTSCHRIFT</AddtlTxInf>
            </TxDtls></NtryDtls>
          </Ntry>
          <Ntry>
            <Amt Ccy="EUR">12.50</Amt>
            <CdtDbtInd>DBIT</CdtDbtInd>
            <Sts>BOOK</Sts>
            <BookgDt><Dt>2023-01-15</Dt></BookgDt>
            <ValDt><Dt>2023-01-16</Dt></ValDt>
            <BkTxCd><Prtry><Cd>177</Cd></Prtry></BkTxCd>
            <NtryDtls><TxDtls>
              <Refs><EndToEndId>E2E-DD</EndToEndId><MndtId>MND-2023</MndtId></Refs>
              <RltdPties>
                <Cdtr><Nm>Stadtwerke</Nm></Cdtr>
                <CdtrAcct><Id><IBAN>DE02120300000000202051</IBAN></Id></CdtrAcct>
                <CdtrSchmeId><Id><PrvtId><Othr><Id>DE98ZZZ09999999999</Id></Othr></PrvtId></Id></CdtrSchmeId>
              </RltdPties>
              <RltdAgts><CdtrAgt><FinInstnId><BICFI>GENODEF1S02</BICFI></FinInstnId></CdtrAgt></RltdAgts>
              <Chrgs><TtlChrgsAndTaxAmt Ccy="EUR">0.35</TtlChrgsAndTaxAmt></Chrgs>
              <RmtInf><Ustrd>Strom Januar</Ustrd><Ustrd>Kundennr 123</Ustrd></RmtInf>
            </TxDtls></NtryDtls>
            <AddtlNtryInf>LASTSCHRIFT</AddtlNtryInf>
          </Ntry>
        </Rpt>
      </BkToCstmrAcctRpt>
    </Document>
  XML

  def parse(xml)
    FinTS::CamtParser.new.parse(xml)
  end

  def test_parses_incoming_entry
    tx = parse(CAMT052).first
    assert_in_delta 96.38, tx[:amount], 0.001
    assert_equal 'EUR', tx[:currency]
    assert_equal 'BOOK', tx[:status]
    assert_equal true, tx[:booked]
    assert_equal Date.new(2023, 1, 15), tx[:booking_date]
    assert_equal Date.new(2023, 1, 15), tx[:value_date]
    # incoming payment -> the other party is the debtor, not us
    assert_equal 'Stripe Payments UK Ltd', tx[:name]
    assert_equal 'DK6689000000010241', tx[:iban]
    assert_equal 'PBNKDEFFXXX', tx[:bic]
    assert_equal 'STRIPEX4J1J3', tx[:purpose]
    assert_equal 'E2E-STRIPE', tx[:end_to_end_id]
    assert_equal 'ASR-ENTRY-1', tx[:reference]
    assert_equal 'SEPA GUTSCHRIFT', tx[:additional_info]
    assert_equal '166', tx[:transaction_code]
  end

  def test_parses_outgoing_entry_with_negative_amount
    tx = parse(CAMT052)[1]
    assert_in_delta(-12.5, tx[:amount], 0.001)
    assert_equal 'Stadtwerke', tx[:name]
    assert_equal 'DE02120300000000202051', tx[:iban]
    assert_equal 'GENODEF1S02', tx[:bic] # BICFI (camt …001.08 style tag)
    # multiple <Ustrd> lines are joined
    assert_equal 'Strom Januar Kundennr 123', tx[:purpose]
    assert_equal 'MND-2023', tx[:mandate_id]
    assert_equal 'DE98ZZZ09999999999', tx[:creditor_id] # unwrapped from the id scaffolding
    assert_equal 'LASTSCHRIFT', tx[:additional_info]
    assert_equal '177', tx[:transaction_code]
  end

  # The whole point: metadata the parser does not lift to a named field must
  # still be reachable through :raw, losslessly.
  def test_raw_preserves_everything_including_unlifted_fields
    tx = parse(CAMT052).first
    raw = tx[:raw]

    # attributes + text are both kept
    assert_equal({ '@Ccy' => 'EUR', '#text' => '96.38' }, raw['Amt'])
    assert_equal 'CRDT', raw['CdtDbtInd']

    # currency-exchange amount details are NOT a top-level field, but survive
    instd = raw.dig('NtryDtls', 'TxDtls', 'AmtDtls', 'InstdAmt')
    assert_equal({ '@Ccy' => 'USD', '#text' => '100.00' }, instd)

    # repeated elements collapse into an array
    tx2 = parse(CAMT052)[1]
    assert_equal %w[Strom\ Januar Kundennr\ 123],
                 tx2[:raw].dig('NtryDtls', 'TxDtls', 'RmtInf', 'Ustrd')
    # charges survive even though there is no named field for them
    assert_equal({ '@Ccy' => 'EUR', '#text' => '0.35' },
                 tx2[:raw].dig('NtryDtls', 'TxDtls', 'Chrgs', 'TtlChrgsAndTaxAmt'))
  end

  def test_raw_drops_namespace_declaration
    raw = parse(CAMT052).first[:raw]
    refute raw.key?('@xmlns'), 'xmlns declaration must not pollute the raw hash'
  end

  def test_returns_all_entries
    assert_equal 2, parse(CAMT052).length
  end

  def test_concatenated_documents_are_all_parsed
    txs = parse(CAMT052 + "\n" + CAMT052)
    assert_equal 4, txs.length
  end

  def test_pending_entry_is_marked_not_booked
    pending = CAMT052.sub('<Sts>BOOK</Sts>', '<Sts>PDNG</Sts>')
    tx = parse(pending).first
    assert_equal 'PDNG', tx[:status]
    assert_equal false, tx[:booked]
  end

  # camt …001.08 nests the status code in <Sts><Cd>…</Cd></Sts>
  def test_nested_status_code_is_supported
    nested = CAMT052.sub('<Sts>BOOK</Sts>', '<Sts><Cd>BOOK</Cd></Sts>')
    assert_equal true, parse(nested).first[:booked]
  end

  def test_falls_back_to_domain_code_without_proprietary_code
    xml = CAMT052.sub('<BkTxCd><Domn><Cd>PMNT</Cd></Domn><Prtry><Cd>166</Cd></Prtry></BkTxCd>',
                      '<BkTxCd><Domn><Cd>PMNT</Cd></Domn></BkTxCd>')
    assert_equal 'PMNT', parse(xml).first[:transaction_code]
  end

  def test_empty_and_nil_input
    assert_empty parse('')
    assert_empty parse(nil)
    assert_empty parse('   ')
  end

  def test_handles_datetime_booking_dates
    xml = CAMT052.sub('<BookgDt><Dt>2023-01-15</Dt></BookgDt>',
                      '<BookgDt><DtTm>2023-01-15T14:30:00</DtTm></BookgDt>')
    assert_equal Date.new(2023, 1, 15), parse(xml).first[:booking_date]
  end
end
