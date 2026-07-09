require 'test_helper'

# HIPINS tells us which operations need a TAN. An HKTAN must be attached to an
# order only when its GV requires one - sending it for a GV that does not
# (e.g. a securities depot listing via HKWPD) is rejected with
# "9010 - ... kann nicht verteilt signiert werden".
class TanRequirementsTest < Minitest::Test
  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  def test_get_tan_requirements_parses_hipins
    data = 'HIPINS:4:1:3+1+1+0+6:16:6:BenutzerID:KundenID:HKSAL:J:HKCAZ:N:HKWPD:N' \
           "'HNHBS:5:1+2'"
    reqs = FinTS::Response.new(data).get_tan_requirements
    assert_equal true,  reqs['HKSAL']
    assert_equal false, reqs['HKCAZ']
    assert_equal false, reqs['HKWPD']
  end

  def test_tan_required_defaults_to_true_for_unknown_operation
    dialog = FinTS::Dialog.new('778000111', 'user', 'pin', 0, nil)
    assert dialog.tan_required?('HKSAL')
  end

  def test_tan_requirements_learned_and_round_trip
    d = FinTS::Dialog.new('778000111', 'user', 'pin', 0, nil)
    d.read_parameters(FinTS::Response.new("HIPINS:4:1:3+1+1+0+HKWPD:N:HKSAL:J'HNHBS:5:1+2'"))
    refute d.tan_required?('HKWPD')
    assert d.tan_required?('HKSAL')

    restored = FinTS::Dialog.new('778000111', 'user', 'pin', 0, nil)
    restored.restore(d.parameters)
    refute restored.tan_required?('HKWPD')
    assert restored.tan_required?('HKSAL')
  end

  # --- order building ---------------------------------------------------------

  def account
    { iban: 'DE12345678901234567890', bic: 'ABCDEFGH1DEF',
      accountnumber: '123456', subaccount: 'Depot', blz: '778000111' }
  end

  def dialog_with(requirements)
    d = FinTS::Dialog.new('778000111', 'user', 'pin', 'SYS', nil)
    d.instance_variable_set(:@tan_mechs, ['902'])
    d.hkwpdversion = 5
    d.hktanversion = 6
    d.instance_variable_set(:@tan_requirements, requirements)
    d
  end

  def client
    FinTS::PinTanClient.new('778000111', 'user', 'pin', 'https://example.com/fints')
  end

  def test_holdings_order_omits_hktan_when_no_tan_required
    msg = client.create_get_holdings_message(dialog_with('HKWPD' => false), account).to_s
    assert_includes msg, 'HKWPD:3:5+123456:Depot:280:778000111'
    refute_includes msg, 'HKTAN'
  end

  def test_holdings_order_includes_hktan_when_tan_required
    msg = client.create_get_holdings_message(dialog_with('HKWPD' => true), account).to_s
    assert_includes msg, 'HKTAN:4:6+4+HKWPD'
  end

  def test_holdings_order_includes_hktan_when_requirement_unknown
    # no HIPINS info at all -> default to attaching (safe for PSD2 banks)
    msg = client.create_get_holdings_message(dialog_with({}), account).to_s
    assert_includes msg, 'HKTAN:4:6+4+HKWPD'
  end
end
