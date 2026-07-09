require 'test_helper'

# Tests for the PSD2 strong-customer-authentication (decoupled) flow.
class ScaTest < Minitest::Test
  # Feeds a scripted list of raw responses back to the dialog and records the
  # messages it sent, without touching the network.
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

  # --- Response parsing -------------------------------------------------------

  def test_get_supported_tan_mechanisms_returns_all_allowed_codes
    resp = FinTS::Response.new("HIRMS:4:2+3920::Zugelassene Verfahren:942:972'")
    assert_equal %w[942 972], resp.get_supported_tan_mechanisms
  end

  def test_get_supported_tan_mechanisms_false_when_none
    resp = FinTS::Response.new("HIRMG:2:2+0010::ok'")
    assert_equal false, resp.get_supported_tan_mechanisms
  end

  def test_get_tan_methods_reads_names_from_hitans
    data = "HIRMS:4:2+3920::Zugelassene Verfahren:942:972'" \
           "HITANS:5:6:4+1+1+0+N:N:0:942:2:MTAN2:HHD1.4:1:mobileTAN Verfahren:6:1:TAN:0:0" \
           ":972:2:PPTAN:HHDOPT1:1:pushTAN 2.0:6:1:TAN:0:0'"
    methods = FinTS::Response.new(data).get_tan_methods
    assert_equal [
      { security_function: '942', name: 'mobileTAN Verfahren' },
      { security_function: '972', name: 'pushTAN 2.0' }
    ], methods
  end

  def test_get_hktan_max_version_from_hitans
    resp = FinTS::Response.new("HITANS:5:7:4+1+1+0+N'")
    assert_equal 7, resp.get_hktan_max_version
  end

  def test_get_tan_order_reference
    resp = FinTS::Response.new("HITAN:4:6:5+4++ORDERREF123+Bitte in der App bestaetigen'")
    assert_equal 'ORDERREF123', resp.get_tan_order_reference
  end

  def test_sca_return_code_helpers
    required = FinTS::Response.new("HIRMS:3:2+0030::Sicherheitsfreigabe erforderlich'")
    assert required.sca_required?

    pending = FinTS::Response.new("HIRMS:3:2+3956::Authentifizierung noch ausstehend'")
    assert pending.sca_required?
    assert pending.decoupled_pending?
    refute pending.sca_approved?

    approved = FinTS::Response.new("HIRMS:3:2+0020::Auftrag ausgefuehrt'")
    refute approved.decoupled_pending?
    assert approved.sca_approved?
  end

  # --- Dialog / decoupled polling --------------------------------------------

  def build_dialog(conn, tan_mechs: ['942'])
    dialog = FinTS::Dialog.new('788000111', 'user', 'pin', 'SYSID', conn,
                               poll_interval: 0, max_poll_attempts: 5)
    dialog.instance_variable_set(:@tan_mechs, tan_mechs)
    dialog.hktanversion = 6
    dialog
  end

  def hnhbk(msgno)
    "HNHBK:1:3+000000000100+300+DIALOG42+#{msgno}'"
  end

  def test_init_sends_hktan_and_polls_decoupled_until_approved
    init_resp = hnhbk(2) +
                "HIRMG:2:2+0010::Nachricht entgegengenommen'" \
                "HIRMS:3:2+0030::Sicherheitsfreigabe erforderlich'" \
                "HITAN:4:6:5+4++ORDERREF123+Bitte in der App bestaetigen'HNHBS:5:1+2'"
    pending_resp = hnhbk(3) +
                   "HIRMG:2:2+0010::ok'HIRMS:3:2+3956::noch ausstehend'HNHBS:4:1+3'"
    approved_resp = hnhbk(4) +
                    "HIRMG:2:2+0020::erfolgreich'HIRMS:3:2+0020::ausgefuehrt'HNHBS:4:1+4'"

    conn = ScriptedConnection.new([init_resp, pending_resp, approved_resp])
    build_dialog(conn).init

    assert_equal 3, conn.sent.length, 'expected init + 2 status polls'
    assert_includes conn.sent[0], 'HKTAN:5:6+4+HKIDN'
    assert_includes conn.sent[1], 'HKTAN:3:6+S++++ORDERREF123'
    assert_includes conn.sent[2], 'HKTAN:3:6+S++++ORDERREF123'
  end

  def test_init_without_challenge_does_not_poll
    # PSD2 90-day read exemption: bank accepts the dialog without a challenge.
    exempt_resp = hnhbk(2) +
                  "HIRMG:2:2+0010::Nachricht entgegengenommen'HNHBS:3:1+2'"
    conn = ScriptedConnection.new([exempt_resp])
    build_dialog(conn).init

    assert_equal 1, conn.sent.length, 'no polling expected'
    assert_includes conn.sent[0], 'HKTAN:5:6+4+HKIDN'
  end

  def test_init_raises_when_decoupled_not_approved_in_time
    init_resp = hnhbk(2) +
                "HIRMG:2:2+0010::ok'HIRMS:3:2+0030::Freigabe erforderlich'" \
                "HITAN:4:6:5+4++ORDERREF123+bitte bestaetigen'HNHBS:5:1+2'"
    pending = hnhbk(3) + "HIRMG:2:2+0010::ok'HIRMS:3:2+3956::ausstehend'HNHBS:4:1+3'"
    # always pending -> exhausts the 5 allowed attempts
    conn = ScriptedConnection.new([init_resp] + Array.new(6, pending))

    error = assert_raises(FinTS::DialogError) { build_dialog(conn).init }
    assert_match(/not approved/, error.message)
  end

  def test_no_hktan_when_only_single_step_available
    resp = hnhbk(2) + "HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    conn = ScriptedConnection.new([resp])
    build_dialog(conn, tan_mechs: ['999']).init

    refute_includes conn.sent[0], 'HKTAN'
  end
end
