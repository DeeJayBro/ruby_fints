require 'test_helper'

# The bank advertises CAMT support via HICAZS: the HKCAZ version and the list of
# supported camt message descriptors. These must be learned during sync/BPD and
# survive a later response that omits the BPD (mirroring the HKTAN handling).
class CamtNegotiationTest < Minitest::Test
  CAMT052 = 'urn:iso:std:iso:20022:tech:xsd:camt.052.001.02'.freeze
  CAMT053 = 'urn:iso:std:iso:20022:tech:xsd:camt.053.001.02'.freeze

  # HICAZS with both descriptors, their URN colons FinTS-escaped as on the wire.
  def hicazs(version: 1)
    esc = ->(d) { FinTS::Helper.fints_escape(d) }
    "HICAZS:7:#{version}:4+1+1+0+J:N:90:#{esc.call(CAMT052)}:#{esc.call(CAMT053)}'HNHBS:8:1+2'"
  end

  def setup
    FinTS::Client.logger.level = Logger::ERROR
  end

  # --- response parsing ------------------------------------------------------

  def test_get_camt_descriptors_recovers_full_urns
    descriptors = FinTS::Response.new(hicazs).get_camt_descriptors
    assert_equal [CAMT052, CAMT053], descriptors
  end

  def test_get_camt_descriptors_handles_single_descriptor
    esc = FinTS::Helper.fints_escape(CAMT052)
    resp = FinTS::Response.new("HICAZS:7:1:4+1+1+0+J:N:90:#{esc}'HNHBS:8:1+2'")
    assert_equal [CAMT052], resp.get_camt_descriptors
  end

  def test_get_camt_descriptors_empty_without_hicazs
    resp = FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'")
    assert_empty resp.get_camt_descriptors
  end

  def test_get_hkcaz_max_version_starts_at_one_not_three
    assert_equal 1, FinTS::Response.new(hicazs(version: 1)).get_hkcaz_max_version
    assert_equal 2, FinTS::Response.new(hicazs(version: 2)).get_hkcaz_max_version
  end

  # --- dialog descriptor selection -------------------------------------------

  def test_dialog_prefers_camt052
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.camt_descriptors = [CAMT053, CAMT052]
    assert_equal CAMT052, dialog.camt_descriptor
  end

  def test_dialog_camt_descriptor_nil_without_support
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    assert_nil dialog.camt_descriptor
  end

  # --- learning + persistence ------------------------------------------------

  def test_read_parameters_learns_version_and_descriptors
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.read_parameters(FinTS::Response.new(hicazs(version: 1)))
    assert_equal 1, dialog.hkcazversion
    assert_equal [CAMT052, CAMT053], dialog.camt_descriptors
    assert_equal CAMT052, dialog.camt_descriptor
  end

  def test_descriptors_survive_a_bpd_skipping_response
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.read_parameters(FinTS::Response.new(hicazs(version: 1)))
    # authenticated response without HICAZS must not wipe what we learned
    dialog.read_parameters(FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'"))
    assert_equal [CAMT052, CAMT053], dialog.camt_descriptors
  end

  def test_parameters_round_trip_through_restore
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    dialog.read_parameters(FinTS::Response.new(hicazs(version: 1)))

    restored = FinTS::Dialog.new('778000111', 'hermes', '1234', 0, nil)
    restored.restore(dialog.parameters)
    assert_equal 1, restored.hkcazversion
    assert_equal [CAMT052, CAMT053], restored.camt_descriptors
  end
end
