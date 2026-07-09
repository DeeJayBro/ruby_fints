require 'test_helper'

# Return code 3076 ("Starke Kundenauthentifizierung nicht notwendig") is the
# bank telling us no SCA is needed for this operation (e.g. a securities depot
# listing). It must be treated as authoritative: no TAN flow, just use the
# result.
class ScaNotRequiredTest < Minitest::Test
  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  def resp_3076
    FinTS::Response.new(
      "HIRMS:5:2:5+3076::Starke Kundenauthentifizierung nicht notwendig.'HNHBS:6:1+2'"
    )
  end

  def test_sca_not_required_detected
    assert resp_3076.sca_not_required?
    refute resp_3076.sca_required?
  end

  def test_3076_overrides_a_security_release_code
    resp = FinTS::Response.new(
      "HIRMS:5:2:5+0030::Sicherheitsfreigabe erforderlich+3076::nicht notwendig'HNHBS:6:1+2'"
    )
    refute resp.sca_required?, '3076 must override 0030'
  end

  def test_complete_strong_authentication_is_a_noop_and_sends_nothing
    conn = Object.new
    def conn.send_msg(_msg)
      raise 'no message should be sent when SCA is not necessary'
    end

    dialog = FinTS::Dialog.new('778000111', 'user', 'pin', 'SYS', conn, poll_interval: 0)
    dialog.instance_variable_set(:@tan_mechs, ['902'])

    resp = resp_3076
    assert_same resp, dialog.complete_strong_authentication(resp)
  end
end
