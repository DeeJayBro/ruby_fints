require 'test_helper'

# The bank advertises CAMT support via HICAZS: the HKCAZ version and the list of
# supported camt message descriptors. These must be learned during sync/BPD and
# survive a later response that omits the BPD (mirroring the HKTAN handling).
class CamtNegotiationTest < Minitest::Test
  CAMT052 = 'urn:iso:std:iso:20022:tech:xsd:camt.052.001.02'.freeze
  CAMT053 = 'urn:iso:std:iso:20022:tech:xsd:camt.053.001.02'.freeze

  # HICAZS with both descriptors, their URN colons FinTS-escaped as on the wire.
  # The CAMT parameter data group is "Speicherzeitraum:AlleKonten:AnzahlEintraege
  # :<camt descriptors...>", matching the real segment structure.
  def hicazs(version: 1, storage_days: 9999)
    esc = ->(d) { FinTS::Helper.fints_escape(d) }
    "HICAZS:7:#{version}:4+999+1+0+#{storage_days}:J:N:#{esc.call(CAMT052)}:#{esc.call(CAMT053)}'HNHBS:8:1+2'"
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
    resp = FinTS::Response.new("HICAZS:7:1:4+999+1+0+9999:J:N:#{esc}'HNHBS:8:1+2'")
    assert_equal [CAMT052], resp.get_camt_descriptors
  end

  def test_get_camt_storage_days
    assert_equal 9999, FinTS::Response.new(hicazs).get_camt_storage_days
    assert_equal 60,   FinTS::Response.new(hicazs(storage_days: 60)).get_camt_storage_days
  end

  def test_get_camt_storage_days_nil_without_hicazs
    assert_nil FinTS::Response.new("HIRMG:2:2+0010::ok'HNHBS:3:1+2'").get_camt_storage_days
  end

  # The real-world segment from a live BPD: Speicherzeitraum is the first element
  # of the parameter group, regardless of how many common fields precede it.
  def test_get_camt_storage_days_from_live_segment
    seg = "HICAZS:17:1:3+999+1+0+9999:J:N:" \
          "urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.02:" \
          "urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.02.xsd'"
    assert_equal 9999, FinTS::Response.new(seg).get_camt_storage_days
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
    dialog.read_parameters(FinTS::Response.new(hicazs(version: 1, storage_days: 9999)))
    assert_equal 1, dialog.hkcazversion
    assert_equal [CAMT052, CAMT053], dialog.camt_descriptors
    assert_equal CAMT052, dialog.camt_descriptor
    assert_equal 9999, dialog.camt_storage_days
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
    assert_equal 9999, restored.camt_storage_days
  end

  # --- client exposure -------------------------------------------------------

  def test_client_exposes_camt_storage_days_from_cached_bpd
    client = FinTS::PinTanClient.new('778000111', 'hermes', '1234', 'https://example.com/fints')
    assert_nil client.camt_storage_days, 'unknown until the BPD has been fetched'

    client.instance_variable_set(:@bpd, { camt_storage_days: 9999 })
    assert_equal 9999, client.camt_storage_days
  end
end
