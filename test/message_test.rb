require 'test_helper'

class MessageTest < Minitest::Test
  BLZ  = '788000111'
  USER = 'my?user'
  PIN  = 'mypw'

  # Builds an anonymous dialog-init message the same way Dialog#check_bpd does.
  def anonymous_message
    seg_identification = FinTS::Segment::HKIDN.new(3, BLZ, '9999999999', 0, 0)
    seg_prepare = FinTS::Segment::HKVVB.new(4)
    FinTS::Message.new(BLZ, USER, PIN, 0, 0, 1,
                       [seg_identification, seg_prepare], skip_signature: true)
  end

  # FinTS 3.0 Formals, section C.5: an anonymous message must not be signed
  # or encrypted.
  def test_anonymous_message_has_no_signature_or_encryption_segments
    msg = anonymous_message.to_s
    %w[HNVSK HNVSD HNSHK HNSHA].each do |seg|
      refute_includes msg, seg, "anonymous message must not contain #{seg}"
    end
    refute_includes msg, PIN, 'anonymous message must not carry the PIN'
  end

  def test_anonymous_message_layout_is_sequential_plaintext
    msg = anonymous_message.to_s
    assert_includes msg, "HKIDN:2:2+280:#{BLZ}+9999999999+0+0'"
    assert_includes msg, 'HKVVB:3:3+0+0+1+'
    assert_includes msg, "HNHBS:4:1+1'"
    assert msg.start_with?('HNHBK:1:3+'), 'message must start with the header'
  end

  # The message header length must equal the actual message length, otherwise
  # the bank rejects the message.
  def test_anonymous_message_header_length_is_correct
    msg = anonymous_message.to_s
    declared = msg[/\AHNHBK:1:3\+(\d{12})\+/, 1]
    refute_nil declared, 'header length field not found'
    assert_equal msg.bytesize, declared.to_i
  end

  # The Sicherheitsreferenznummer (HNSHK DE7) must increase with each signed
  # message in a dialog, otherwise strict banks reject the second message with
  # "9340 Ungültige Signatur" (this broke the decoupled SCA status poll).
  def test_signature_reference_number_tracks_message_number
    Delorean.time_travel_to(Time.new(2017, 4, 20, 17, 17)) do
      seg = FinTS::Segment::HKIDN.new(3, BLZ, USER, 'SYS')
      msg1 = FinTS::Message.new(BLZ, USER, PIN, 'SYS', 0, 1, [seg], ['942']).to_s
      msg2 = FinTS::Message.new(BLZ, USER, PIN, 'SYS', 0, 2, [seg], ['942']).to_s
      assert_match(/1::SYS\+1\+1:/, msg1)
      assert_match(/1::SYS\+2\+1:/, msg2)
    end
  end

  # Regression guard: authenticated messages must still be encrypted and signed.
  def test_signed_message_still_has_encryption_envelope
    Delorean.time_travel_to(Time.new(2017, 4, 20, 17, 17)) do
      msg = FinTS::Message.new(BLZ, USER, PIN, 0, 5, 2,
                               [FinTS::Segment::HKIDN.new(3, BLZ, USER, 0)], ['999']).to_s
      %w[HNVSK HNVSD HNSHK HNSHA].each do |seg|
        assert_includes msg, seg, "signed message must contain #{seg}"
      end
    end
  end
end
