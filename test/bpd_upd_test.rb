require 'test_helper'

# Once the bank has reported its bank/user parameter data versions (HIBPA /
# HIUPA), the client should echo them back in HKVVB instead of always sending 0.
class BpdUpdTest < Minitest::Test
  class RecordingConnection
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

  # --- Response parsing ------------------------------------------------------

  def test_get_bpd_version
    resp = FinTS::Response.new("HIBPA:3:3:4+7+280:778000111+Test Bank+3+de+300'HNHBS:4:1+2'")
    assert_equal 7, resp.get_bpd_version
  end

  def test_get_upd_version
    resp = FinTS::Response.new("HIUPA:4:4:4+hermes+5+0'HNHBS:5:1+2'")
    assert_equal 5, resp.get_upd_version
  end

  def test_versions_default_to_zero_when_absent
    resp = FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'")
    assert_equal 0, resp.get_bpd_version
    assert_equal 0, resp.get_upd_version
  end

  # --- End-to-end: init echoes the versions learned during sync --------------

  def test_init_supplies_bpd_and_upd_versions_learned_during_sync
    sync_resp = "HNHBK:1:3+000000000100+300+DLG1+2'" \
                "HISYN:2:4:3+SYS123'" \
                "HIBPA:3:3:4+7+280:778000111+Test Bank+3+de+300'" \
                "HIUPA:4:4:4+hermes+5+0'" \
                "HIRMG:5:2+0010::ok'HNHBS:6:1+2'"
    end_resp = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:3:1+3'"
    init_resp = "HNHBK:1:3+000000000100+300+DLG2+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"

    conn = RecordingConnection.new([sync_resp, end_resp, init_resp])
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, conn, poll_interval: 0)
    dialog.sync
    dialog.init

    # sync is the first contact, so nothing is known yet -> 0/0
    assert_includes conn.sent[0], 'HKVVB:4:3+0+0+1'
    # init echoes the versions the bank reported during sync
    assert_includes conn.sent[2], 'HKVVB:4:3+7+5+1'
  end

  def test_known_versions_are_kept_when_a_later_response_omits_them
    resp_with = FinTS::Response.new(
      "HIBPA:3:3:4+7+280:778000111+Test Bank'HIUPA:4:4:4+hermes+5+0'HNHBS:5:1+2'"
    )
    resp_without = FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'")

    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.update_bpd_upd_versions(resp_with)
    dialog.update_bpd_upd_versions(resp_without)

    assert_includes dialog.hkvvb_segment(4).to_s, 'HKVVB:4:3+7+5+1'
  end
end
