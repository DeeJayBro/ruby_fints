require 'test_helper'

# PSD2 process variant 2: business orders (HKSAL/HKCAZ/HKWPD) must carry their
# own HKTAN and complete strong authentication; the result is delivered in the
# decoupled approval response.
class OrderScaTest < Minitest::Test
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

  def client
    FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
  end

  # Dialog with a two-step TAN mechanism advertised (so HKTAN must be attached).
  def two_step_dialog(conn = nil)
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 'SYSID', conn,
                               poll_interval: 0, max_poll_attempts: 5)
    dialog.instance_variable_set(:@tan_mechs, ['942'])
    dialog.hksalversion = 8
    dialog.hkcazversion = 1
    dialog.hkwpdversion = 7
    dialog.hktanversion = 6
    dialog.camt_descriptors = ['urn:iso:std:iso:20022:tech:xsd:camt.052.001.02']
    dialog
  end

  # --- HKTAN attachment on orders --------------------------------------------

  def test_balance_order_carries_hktan_for_hksal
    msg = client.create_balance_message(two_step_dialog, account).to_s
    assert_includes msg, 'HKSAL:3:8+DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111+N'
    assert_includes msg, 'HKTAN:4:6+4+HKSAL'
  end

  def test_holdings_order_carries_hktan_for_hkwpd
    msg = client.create_get_holdings_message(two_step_dialog, account).to_s
    assert_includes msg, 'HKTAN:4:6+4+HKWPD'
  end

  def test_statement_order_carries_hktan_only_on_initial_request
    initial = client.create_statement_message(two_step_dialog, account,
                                              Date.new(2026, 1, 1), Date.new(2026, 1, 31), nil).to_s
    assert_includes initial, 'HKCAZ:3:1+DE12345678901234567890:ABCDEFGH1DEF+'
    assert_includes initial, 'HKTAN:4:6+4+HKCAZ'

    continuation = client.create_statement_message(two_step_dialog, account,
                                                   Date.new(2026, 1, 1), Date.new(2026, 1, 31), 'TD123').to_s
    refute_includes continuation, 'HKTAN'
  end

  def test_no_hktan_when_bank_has_no_two_step_procedure
    dialog = two_step_dialog
    dialog.instance_variable_set(:@tan_mechs, false)
    refute_includes client.create_balance_message(dialog, account).to_s, 'HKTAN'
  end

  # --- Result delivered in the decoupled approval response --------------------

  def test_complete_strong_authentication_returns_approved_response_with_result
    order_resp = FinTS::Response.new(
      "HNHBK:1:3+000000000100+300+DIALOG1+4'" \
      "HIRMG:2:2+0010::Nachricht entgegengenommen'" \
      "HIRMS:3:2+0030::Sicherheitsfreigabe erforderlich'" \
      "HITAN:4:6:5+4++ORDERREF9+bitte in der App bestaetigen'HNHBS:5:1+4'"
    )
    pending = "HNHBK:1:3+000000000100+300+DIALOG1+5'HIRMG:2:2+0010::ok'" \
              "HIRMS:3:2+3956::ausstehend'HNHBS:4:1+5'"
    approved = "HNHBK:1:3+000000000100+300+DIALOG1+6'HIRMG:2:2+0020::erfolgreich'" \
               "HIRMS:3:2+0020::ausgefuehrt'" \
               "HISAL:4:8:5+DE12345678901234567890:ABCDEFGH1DEF:123456::280:778000111" \
               "+EUR+C:1234,56:EUR:20260707'HNHBS:5:1+6'"

    conn = ScriptedConnection.new([pending, approved])
    dialog = two_step_dialog(conn)
    dialog.instance_variable_set(:@dialog_id, 'DIALOG1')

    final = dialog.complete_strong_authentication(order_resp)

    assert_equal 2, conn.sent.length, 'expected two status polls'
    assert_includes conn.sent[0], 'HKTAN:3:6+S++++ORDERREF9'
    refute_nil final.find_segment('HISAL'), 'balance result must come from the approved poll response'
  end

  def test_complete_strong_authentication_passes_through_when_exempt
    exempt = FinTS::Response.new(
      "HNHBK:1:3+000000000100+300+DIALOG1+4'HIRMG:2:2+0010::ok'" \
      "HISAL:3:8:4+DE12+BIC+EUR+C:5,00:EUR:20260707'HNHBS:4:1+4'"
    )
    conn = ScriptedConnection.new([])
    dialog = two_step_dialog(conn)

    final = dialog.complete_strong_authentication(exempt)
    assert_same exempt, final
    assert_equal 0, conn.sent.length, 'no polling when the bank did not challenge'
  end
end
