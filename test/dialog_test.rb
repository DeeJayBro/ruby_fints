require 'test_helper'

class DialogTest < Minitest::Test
  # Captures the messages a dialog sends without touching the network.
  class RecordingConnection
    attr_reader :sent

    def initialize
      @sent = []
    end

    def send_msg(msg)
      @sent << msg.to_s
      '' # empty response -> no HIRMG -> Dialog#send_msg treats it as successful
    end
  end

  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  # Since PSD2 the product identifier (HKVVB "Produktbezeichnung") must be the
  # registration number assigned by the Deutsche Kreditwirtschaft, otherwise the
  # bank aborts the dialog with "9078 - Banking-Programm ist nicht registriert".
  def test_configured_product_name_reaches_hkvvb
    conn = RecordingConnection.new
    dialog = FinTS::Dialog.new('788000111', 'user', 'pin', 0, conn,
                               product_name: 'REG123456', product_version: '9.9')
    dialog.check_bpd

    anonymous_init = conn.sent.first
    assert_includes anonymous_init, 'HKVVB:3:3+0+0+1+REG123456+9.9'
    refute_includes anonymous_init, 'ruby_fints'
  end

  def test_defaults_to_gem_name_when_product_not_configured
    conn = RecordingConnection.new
    dialog = FinTS::Dialog.new('788000111', 'user', 'pin', 0, conn)
    dialog.check_bpd

    assert_includes conn.sent.first, "HKVVB:3:3+0+0+1+ruby_fints+#{FinTS::VERSION}"
  end

  def test_pin_tan_client_threads_product_into_dialog
    client = FinTS::PinTanClient.new('788000111', 'user', 'pin',
                                     'https://example.com/fints',
                                     product_name: 'REG123456', product_version: '9.9')
    dialog = client.send(:new_dialog)
    dialog.instance_variable_set(:@connection, conn = RecordingConnection.new)
    dialog.check_bpd

    assert_includes conn.sent.first, 'HKVVB:3:3+0+0+1+REG123456+9.9'
  end
end
