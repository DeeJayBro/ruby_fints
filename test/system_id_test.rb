require 'test_helper'

# The customer system ID (Kundensystem-ID) and bank parameter data are obtained
# once via synchronisation and then reused, so repeated operations do not keep
# registering new customer systems.
class SystemIdTest < Minitest::Test
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

  def test_parameters_restore_round_trip
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.instance_variable_set(:@system_id, 'SYS123')
    dialog.instance_variable_set(:@tan_mechs, ['942'])
    dialog.hksalversion = 8
    dialog.hktanversion = 6

    params = dialog.parameters
    assert_equal 'SYS123', params[:system_id]

    restored = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    restored.restore(params)
    assert_equal 'SYS123', restored.system_id
    assert_equal ['942'], restored.tan_mechs
    assert_equal 8, restored.hksalversion
    assert_equal 6, restored.hktanversion
  end

  def sync_resp
    "HNHBK:1:3+000000000100+300+DLG1+2'" \
    "HISYN:2:4:3+SYS123'" \
    "HIBPA:3:3:4+7+280:778000111+Test Bank+3+de+300'" \
    "HIUPA:4:4:4+hermes+5+0'" \
    "HIRMS:5:2+3920::Zugelassene Verfahren:942'" \
    "HIRMG:6:2+0010::ok'HNHBS:7:1+2'"
  end

  def end_resp
    "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0010::ok'HNHBS:3:1+3'"
  end

  def init_resp(dlg)
    "HNHBK:1:3+000000000100+300+#{dlg}+2'HIRMG:2:2+0010::ok'HNHBS:3:1+2'"
  end

  def test_second_operation_reuses_system_id_and_skips_sync
    conn = ScriptedConnection.new([sync_resp, end_resp, init_resp('DLG2'), init_resp('DLG3')])
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints',
                                     poll_interval: 0)
    client.instance_variable_set(:@connection, conn)

    client.send(:open_dialog) # first: synchronise + init
    first_op = conn.sent.dup

    client.send(:open_dialog) # second: should reuse the cached system ID
    second_op = conn.sent[first_op.length..]

    assert(first_op.any? { |m| m.include?('HKSYN') }, 'first operation must synchronise')
    refute(second_op.any? { |m| m.include?('HKSYN') }, 'second operation must not synchronise again')
    assert(second_op.any? { |m| m.include?('SYS123') },
           'second operation must reuse the learned customer system ID')
    assert_equal 1, second_op.length, 'second operation should only send the dialog init'
  end

  def test_first_operation_still_synchronises
    conn = ScriptedConnection.new([sync_resp, end_resp, init_resp('DLG2')])
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints',
                                     poll_interval: 0)
    client.instance_variable_set(:@connection, conn)

    refute client.dialog_established?
    client.send(:open_dialog)
    assert client.dialog_established?, 'client must remember the system ID after the first sync'
  end
end
