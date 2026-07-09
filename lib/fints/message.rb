module FinTS
  class Message
    attr_accessor :msg_no
    attr_accessor :dialog_id
    attr_accessor :encrypted_segments

    def initialize(blz, username, pin, system_id, dialog_id, msg_no, encrypted_segments, tan_mechs=nil, skip_signature: false, tan: nil)
      @blz = blz
      @username = username
      @pin = pin
      @tan = tan
      @system_id = system_id
      @dialog_id = dialog_id
      @msg_no = msg_no
      @segments = []
      @encrypted_segments = []

      if tan_mechs && !tan_mechs.include?('999')
        @profile_version = 2
        @security_function = tan_mechs[0]
      else
        @profile_version = 1
        @security_function = '999'
      end

      if skip_signature
        # Anonymous access (FinTS 3.0 Formals, section C.5): the message is
        # transmitted in plaintext, i.e. with neither an encryption envelope
        # (HNVSK/HNVSD) nor a signature (HNSHK/HNSHA). The payload segments
        # follow the message header directly and are numbered sequentially.
        FinTS::Client.logger.debug("Building anonymous message (no signature, no encryption)")
        segno = 2
        encrypted_segments.each do |segment|
          segment.segmentno = segno
          @segments << segment
          @encrypted_segments << segment
          segno += 1
        end

        cur_count = segno - 1
      else
        sig_head = build_signature_head
        enc_head = build_encryption_head
        @segments << enc_head

        @enc_envelop = Segment::HNVSD.new(999, '')
        @segments << @enc_envelop

        append_enc_segment(sig_head)
        encrypted_segments.each do |segment|
          append_enc_segment(segment)
        end

        cur_count = encrypted_segments.length + 3

        sig_end = Segment::HNSHA.new(cur_count, @secref, @pin, tan: @tan)
        append_enc_segment(sig_end)
      end

      @segments << Segment::HNHBS.new(cur_count + 1, msg_no)
    end

    def append_enc_segment(seg)
      @encrypted_segments << seg
      @enc_envelop.set_data(@enc_envelop.encoded_data + seg.to_s)
    end

    def build_signature_head
      @secref = Kernel.rand(1000000..9999999)
      # Use the message number as the (per-dialog, strictly increasing)
      # Sicherheitsreferenznummer so a second signed message in the same dialog
      # (e.g. a decoupled SCA status poll) is not rejected as a replay.
      Segment::HNSHK.new(2, @secref, @blz, @username, @system_id, @profile_version, @security_function, @msg_no)
    end

    def build_encryption_head
      Segment::HNVSK.new(998, @blz, @username, @system_id, @profile_version)
    end

    def build_header
      length = @segments.map(&:to_s).inject(0) { |sum, segment| sum + segment.length }
      Segment::HNHBK.new(length, @dialog_id, @msg_no)
    end

    def to_s
      build_header.to_s + @segments.map(&:to_s).join('')
    end
  end
end
