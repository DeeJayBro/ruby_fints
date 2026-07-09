require 'test_helper'

# The client can tell whether a securities depot listing (HKWPD) is on offer,
# so callers can fetch holdings only when the bank supports it.
class HoldingsAvailableTest < Minitest::Test
  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  def dialog
    FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
  end

  def test_read_parameters_marks_holdings_supported_from_hiwpds
    d = dialog
    refute d.holdings_supported
    d.read_parameters(FinTS::Response.new("HIWPDS:5:6:4+1+1+N'HNHBS:6:1+2'"))
    assert d.holdings_supported
  end

  def test_holdings_supported_survives_a_response_without_hiwpds_and_round_trips
    d = dialog
    d.read_parameters(FinTS::Response.new("HIWPDS:5:6:4+1+1+N'HNHBS:6:1+2'"))
    d.read_parameters(FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'"))
    assert d.holdings_supported

    params = d.parameters
    assert params[:holdings_supported]

    restored = dialog
    restored.restore(params)
    assert restored.holdings_supported
  end

  def test_client_holdings_available_reflects_cached_bpd
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    refute client.holdings_available?, 'unknown before any bank parameter data is fetched'

    d = FinTS::Dialog.new('778000111', 'hermes', '1234', 'SYS', nil)
    d.read_parameters(FinTS::Response.new("HIWPDS:5:6:4+1+1+N'HNHBS:6:1+2'"))
    client.remember_dialog(d)

    assert client.holdings_available?
  end

  def test_client_holdings_unavailable_when_bank_has_no_hiwpds
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    d = FinTS::Dialog.new('778000111', 'hermes', '1234', 'SYS', nil)
    d.read_parameters(FinTS::Response.new("HISALS:3:8:4+1+1+N'HNHBS:4:1+2'"))
    client.remember_dialog(d)

    refute client.holdings_available?
  end
end
