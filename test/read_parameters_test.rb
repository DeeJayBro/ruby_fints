require 'test_helper'

# Regression tests for parameter learning: a response that omits the bank
# parameter data (because we advertised a matching BPD version, or because it is
# the authenticated dialog rather than the anonymous BPD retrieval) must not
# reset versions an earlier response already taught us. Otherwise the HKTAN
# version falls back to 3 and the bank rejects it with
# "9110 Falsche Segmentzusammenstellung: HKTAN".
class ReadParametersTest < Minitest::Test
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

  def dialog
    FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
  end

  def test_hktan_version_learned_from_hitans
    d = dialog
    d.read_parameters(FinTS::Response.new("HITANS:5:6:4+1+1+0+N'HNHBS:6:1+2'"))
    assert_equal 6, d.hktanversion
  end

  def test_hktan_version_not_reset_when_a_later_response_omits_hitans
    d = dialog
    d.read_parameters(FinTS::Response.new("HITANS:5:6:4+1+1+0+N'HNHBS:6:1+2'"))
    assert_equal 6, d.hktanversion

    # authenticated response: HIRMS 3920 present, but the BPD (HITANS) is skipped
    d.read_parameters(FinTS::Response.new("HIRMS:3:2+3920::Verfahren:923'HNHBS:4:1+2'"))
    assert_equal 6, d.hktanversion, 'HKTAN version must survive a BPD-skipping response'
    assert_equal ['923'], d.tan_mechs
  end

  # Full scenario from the bug report: get_sepa_accounts (anonymous BPD + sync)
  # then a second dialog. The second dialog's init must send HKTAN at the version
  # advertised in HITANS (6), not the default 3.
  def test_second_dialog_uses_hktan_version_from_anonymous_bpd
    check_bpd_resp = "HNHBK:1:3+000000000100+300+0+1'" \
                     "HIBPA:2:3:4+20+280:778000111+Test Bank+3+de+300'" \
                     "HISALS:3:8:4+1+1+N'" \
                     "HITANS:4:6:4+1+1+0+N'" \
                     "HIRMG:5:2+0010::ok'HNHBS:6:1+1'"
    cb_end = "HNHBK:1:3+000000000100+300+0+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    # authenticated sync: user TAN mechanisms (3920) but no HITANS (BPD skipped)
    sync_resp = "HNHBK:1:3+000000000100+300+DLG1+2'" \
                "HISYN:2:4:3+SYS123'" \
                "HIRMS:3:2+3920::Zugelassene Verfahren:923'" \
                "HIRMG:4:2+0010::ok'HNHBS:5:1+2'"
    sync_end = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:3:1+3'"
    init1 = "HNHBK:1:3+000000000100+300+DLG2+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
    init2 = "HNHBK:1:3+000000000100+300+DLG3+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"

    conn = ScriptedConnection.new([check_bpd_resp, cb_end, sync_resp, sync_end, init1, init2])
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints',
                                     poll_interval: 0)
    client.instance_variable_set(:@connection, conn)

    client.send(:open_dialog, check_bpd: true) # first operation
    first_len = conn.sent.length
    client.send(:open_dialog)                  # "next dialog after initial sync"
    second_init = conn.sent[first_len..].join

    assert_includes second_init, 'HKTAN:5:6+4+HKIDN'
    refute_includes second_init, 'HKTAN:5:3'
    refute_includes second_init, 'HKSYN'
    assert_includes second_init, 'SYS123'
  end
end
