require 'test_helper'

# Image-based (photoTAN) challenge/response fallback when the bank does not
# offer decoupled app approval.
class PhotoTanTest < Minitest::Test
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

  # A minimal but structurally valid PNG payload (signature + assorted bytes).
  def png
    "\x89PNG\r\n\x1a\n".b + (0..255).to_a.pack('C*') + "IEND\xae\x42\x60\x82".b
  end

  # HITAN carrying a photoTAN image, encoded the way the transport delivers it
  # (ISO-8859-1 on the wire, re-encoded to UTF-8 by HTTPSConnection).
  def challenge_response(order_ref)
    mime = 'image/png'
    hhduc = [mime.bytesize].pack('n') + mime.b + [png.bytesize].pack('n') + png
    hitan = "HITAN:4:6:5+4++#{order_ref}+Siehe Grafik+@#{hhduc.bytesize}@#{hhduc}"
    wire = ("HNHBK:1:3+000000000100+300+DLG1+2'" \
            "HIRMG:2:2+0010::ok'" \
            "HIRMS:3:2+0030::Sicherheitsfreigabe erforderlich'" \
            "#{hitan}'HNHBS:5:1+2'").b
    FinTS::Response.new(wire.force_encoding('iso-8859-1').encode('utf-8'))
  end

  # --- Segments ---------------------------------------------------------------

  def test_hnsha_carries_pin_and_tan
    seg = FinTS::Segment::HNSHA.new(4, 5616216, 'mypin', tan: '123456')
    assert_equal "HNSHA:4:2+5616216++mypin:123456'", seg.to_s
  end

  def test_hnsha_without_tan_is_pin_only
    seg = FinTS::Segment::HNSHA.new(4, 5616216, 'mypin')
    assert_equal "HNSHA:4:2+5616216++mypin'", seg.to_s
  end

  def test_hktan_tan_submission
    seg = FinTS::Segment::HKTAN.new(3, 6, '2', order_ref: 'ORDERREF9')
    assert_equal "HKTAN:3:6+2++++ORDERREF9+N'", seg.to_s
  end

  def test_message_puts_tan_into_hnsha
    msg = FinTS::Message.new('778000111', 'hermes', '1234', 0, 5, 2,
                             [FinTS::Segment::HKTAN.new(3, 6, '2', order_ref: 'ORDERREF9')],
                             ['942'], tan: '123456').to_s
    assert_includes msg, '1234:123456'
  end

  # --- Response parsing -------------------------------------------------------

  def test_challenge_text_and_image_extraction
    resp = challenge_response('46562992')
    assert_equal '46562992', resp.get_tan_order_reference
    assert_equal 'Siehe Grafik', resp.get_tan_challenge
    image = resp.get_tan_challenge_image
    assert_equal png, image
    assert image.start_with?("\x89PNG".b)
  end

  # --- Dialog fallback flow ---------------------------------------------------

  def test_image_challenge_invokes_handler_and_submits_tan
    approved = "HNHBK:1:3+000000000100+300+DLG1+3'HIRMG:2:2+0020::ok'" \
               "HIRMS:3:2+0020::ausgefuehrt'" \
               "HISAL:4:8:5+DE12+ABCDEFGH1DEF+EUR+C:1234,56:EUR:20260707'HNHBS:5:1+3'"
    conn = ScriptedConnection.new([approved])

    received = nil
    handler = ->(challenge) { received = challenge; '123456' }
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 'SYSID', conn,
                               tan_handler: handler, poll_interval: 0)
    dialog.instance_variable_set(:@tan_mechs, ['942'])
    dialog.hktanversion = 6
    dialog.instance_variable_set(:@dialog_id, 'DLG1')

    final = dialog.complete_strong_authentication(challenge_response('ORDERREF9'))

    # handler saw the challenge
    assert_equal 'Siehe Grafik', received[:text]
    assert received[:image].start_with?("\x89PNG".b)
    assert_equal 'ORDERREF9', received[:order_ref]

    # a TAN submission (HKTAN process 2) carrying the entered TAN was sent
    assert_equal 1, conn.sent.length
    assert_includes conn.sent[0], 'HKTAN:3:6+2++++ORDERREF9'
    assert_includes conn.sent[0], '1234:123456'

    # the order result comes back once the TAN is accepted
    refute_nil final.find_segment('HISAL')
  end

  def test_image_challenge_without_handler_raises_clear_error
    dialog = FinTS::Dialog.new('778000111', 'hermes', '1234', 'SYSID', nil, poll_interval: 0)
    dialog.instance_variable_set(:@tan_mechs, ['942'])
    dialog.hktanversion = 6

    error = assert_raises(FinTS::DialogError) do
      dialog.complete_strong_authentication(challenge_response('ORDERREF9'))
    end
    assert_match(/tan_handler/, error.message)
  end
end
