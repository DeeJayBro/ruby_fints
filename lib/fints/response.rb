module FinTS
  class Response
    RE_SEGMENTS = /'(?=[A-Z]{4,}:\d|')/
    RE_UNWRAP = /HNVSD:\d+:\d+\+@\d+@(.+)''/
    RE_SYSTEMID = /HISYN:\d+:\d+:\d+\+(.+)/
    RE_TANMECH = /\d{3}/

    # PSD2 strong-customer-authentication return codes (HIRMG/HIRMS).
    SCA_REQUIRED_CODES     = %w[0030].freeze # security release required after HKTAN
    SCA_PENDING_CODES      = %w[3955 3956].freeze # decoupled: not yet approved in app
    SCA_APPROVED_CODES     = %w[0020].freeze # strong authentication performed
    SCA_NOT_REQUIRED_CODES = %w[3076].freeze # "Starke Kundenauthentifizierung nicht notwendig"

    def initialize(data)
      @response = unwrap(data)
      @segments = data.split(RE_SEGMENTS)
    end

    def split_for_data_groups(seg)
      seg.split(/\+(?<!\?\+)/)
    end

    def split_for_data_elements(deg)
      deg.split(/:(?<!\?:)/)
    end

    def get_summary_by_segment(name)
      if !['HIRMS', 'HIRMG'].include?(name)
        raise ArgumentError, 'Unsupported segment for message summary'
      end

      seg = find_segment(name)
      return {} if seg.nil?
      res = {}
      parts = split_for_data_groups(seg).drop(1)
      parts.each do |de|
        de = split_for_data_elements(de)
        res[de[0]] = de[2]
      end
      res
    end

    def successful?
      summary = get_summary_by_segment('HIRMG')
      summary.each do |code, msg|
        if code[0] == '9'
          return false
        end
      end
      return true
    end

    def get_dialog_id
      seg = self.find_segment('HNHBK')
      unless seg
        raise ArgumentError, 'Invalid response, no HNHBK segment'
      end
      get_segment_index(4, seg)
    end

    def get_system_id
      seg = find_segment('HISYN')
      match = RE_SYSTEMID.match(seg)
      raise ArgumentError, 'Could not find system_id' if match.nil?
      match[1]
    end

    def get_bank_name
      seg = find_segment('HIBPA')
      return nil if seg.nil?
      parts = split_for_data_groups(seg)
      return nil if parts.length <= 3
      parts[3]
    end

    # Version of the bank parameter data (BPD) as reported in HIBPA (data
    # element 1). Returns 0 when the segment is absent.
    def get_bpd_version
      seg = find_segment('HIBPA')
      return 0 if seg.nil?
      parts = split_for_data_groups(seg)
      return 0 if parts.length < 2
      parts[1].to_i
    end

    # Version of the user parameter data (UPD) as reported in HIUPA (data
    # element 2, after the Benutzerkennung). Returns 0 when the segment is
    # absent.
    def get_upd_version
      seg = find_segment('HIUPA')
      return 0 if seg.nil?
      parts = split_for_data_groups(seg)
      return 0 if parts.length < 3
      parts[2].to_i
    end

    # Highest HKCAZ version the bank advertises via HICAZS. Unlike the other
    # segments, HKCAZ/HICAZS numbering starts at 1, so this must not use the
    # version-3 floor that get_segment_max_version applies.
    def get_hkcaz_max_version
      version = 1
      find_segments('HICAZS').each do |s|
        header = split_for_data_elements(split_for_data_groups(s)[0])
        current = header[2].to_i
        version = current if current > version
      end
      version
    end

    # Supported camt message formats advertised in HICAZS (BPD). Each is a full
    # ISO 20022 namespace URN, e.g.
    # 'urn:iso:std:iso:20022:tech:xsd:camt.052.001.02'. The URN's own colons are
    # FinTS-escaped on the wire; unescaping the whole segment first lets a single
    # regex recover the descriptor whether or not the bank escaped it.
    def get_camt_descriptors
      descriptors = []
      find_segments('HICAZS').each do |s|
        unescaped = Helper.fints_unescape(s)
        # non-greedy so two adjacent URNs (both made only of these chars) don't
        # collapse into a single match.
        unescaped.scan(%r{urn:[a-z0-9:.]*?camt\.\d{3}\.\d{3}\.\d{2}}).each { |d| descriptors << d }
      end
      descriptors.uniq
    end

    # Number of days the bank keeps CAMT transactions available for retrieval,
    # i.e. the "Speicherzeitraum" advertised in HICAZS. It is the first element
    # of the segment's CAMT parameter data group (the one carrying the camt
    # descriptors); locating that group by its camt content avoids depending on
    # how many common parameter fields precede it, which varies between banks and
    # segment versions. Returns nil when it is not advertised.
    def get_camt_storage_days
      find_segments('HICAZS').each do |s|
        split_for_data_groups(s).each do |dg|
          next unless dg.include?('camt.')
          first = split_for_data_elements(dg).first.to_s
          return first.to_i if first =~ /\A\d+\z/
        end
      end
      nil
    end

    def get_hksal_max_version
      get_segment_max_version('HISALS')
    end

    def get_hkwpd_max_version
      get_segment_max_version('HIWPDS')
    end

    # HKTAN/HITAN segment version to use; the bank advertises it via HITANS.
    def get_hktan_max_version
      get_segment_max_version('HITANS')
    end

    def get_segment_index(idx, seg)
      seg = split_for_data_groups(seg)
      return seg[idx - 1] if seg.length > idx - 1
      nil
    end

    def get_segment_max_version(name)
      ret = 3
      segs = find_segments(name)
      segs.each do |s|
        parts = split_for_data_groups(s)
        segheader = split_for_data_elements(parts[0])
        current_version = segheader[2].to_i
        if current_version > ret
          ret = current_version
        end
      end
      ret
    end

    # All two-step TAN security functions the bank allows for this user,
    # taken from the HIRMS 3920 feedback (e.g. ['942', '972']). Returns false
    # when none are advertised (keeps the single-step fallback in Message).
    def get_supported_tan_mechanisms
      mechs = []
      find_segments('HIRMS').each do |s|
        split_for_data_groups(s).drop(1).each do |dg|
          des = split_for_data_elements(dg)
          next unless des[0] == '3920'
          # DE0 code, DE1 reference segment, DE2 text, DE3.. allowed functions.
          # chomp a trailing "'" that survives when HIRMS is the last segment.
          des.drop(3).each do |code|
            code = code.chomp("'")
            mechs << code if code =~ /\A\d{3}\z/
          end
        end
      end
      mechs.empty? ? false : mechs.uniq
    end

    # The TAN methods as documented by the bank in HITANS, paired with the
    # allowed security functions from HIRMS 3920. Returns
    # [{ security_function: '942', name: 'pushTAN 2.0' }, ...]. The name is
    # best-effort (its position varies between HITANS versions); the security
    # function is authoritative.
    def get_tan_methods
      allowed = get_supported_tan_mechanisms || []
      seen = {}
      methods = []
      find_segments('HITANS').each do |s|
        groups = split_for_data_groups(s)
        next if groups.length < 5
        params = split_for_data_elements(groups[4])
        params.each_with_index do |code, i|
          next unless allowed.include?(code) && !seen[code]
          window = params[(i + 1)..(i + 6)] || []
          name = window.find { |t| t =~ /[A-Za-zÄÖÜäöüß].*\s/ } ||
                 window.find { |t| t =~ /[A-Za-zÄÖÜäöüß]{2,}/ }
          methods << { security_function: code, name: name }
          seen[code] = true
        end
      end
      allowed.each { |code| methods << { security_function: code, name: nil } unless seen[code] }
      methods
    end

    # Per-operation TAN requirement from HIPINS (the "Geschäftsvorfall-
    # spezifische PIN/TAN-Informationen": each supported segment code followed
    # by a J/N "TAN erforderlich" flag). e.g. {'HKSAL'=>true, 'HKWPD'=>false}.
    # A bank rejects an HKTAN sent for a GV that needs no TAN
    # ("9010 ... kann nicht verteilt signiert werden").
    def get_tan_requirements
      reqs = {}
      find_segments('HIPINS').each do |s|
        tokens = split_for_data_groups(s).flat_map { |g| split_for_data_elements(g) }
        tokens.each_with_index do |code, i|
          next unless code =~ /\A[A-Z]{5,6}\z/
          flag = tokens[i + 1]
          reqs[code] = (flag == 'J') if flag == 'J' || flag == 'N'
        end
      end
      reqs
    end

    # Auftragsreferenz from a HITAN response, needed to poll a decoupled SCA.
    def get_tan_order_reference
      seg = find_segment('HITAN')
      return nil if seg.nil?
      # HITAN: header, TAN-Prozess, Auftrags-Hashwert, Auftragsreferenz, ...
      ref = split_for_data_groups(seg)[3]
      return nil if ref.nil? || ref.empty?
      Helper.fints_unescape(ref)
    end

    # Human-readable challenge text from a HITAN response (data element 4),
    # e.g. "Siehe Grafik" for photoTAN.
    def get_tan_challenge
      seg = find_segment('HITAN')
      return nil if seg.nil?
      text = split_for_data_groups(seg)[4]
      return nil if text.nil? || text.empty?
      Helper.fints_unescape(text)
    end

    # Raw length-prefixed (@len@...) binary challenge from a HITAN response,
    # recovered from the transport's ISO-8859-1 -> UTF-8 re-encoding. For
    # photoTAN this is the HHD-UC container; use #get_tan_challenge_image to get
    # the bare image.
    def get_tan_challenge_binary
      seg = find_segment('HITAN')
      return nil if seg.nil?
      raw = begin
        seg.encode('iso-8859-1').b
      rescue StandardError
        seg.b
      end
      m = /@(\d+)@/.match(raw)
      return nil if m.nil?
      data = raw.byteslice(m.end(0), m[1].to_i)
      (data.nil? || data.empty?) ? nil : data
    end

    # The bare image (e.g. PNG bytes) from a photoTAN challenge. The HHD-UC
    # container is [2-byte mime length][mime type][2-byte image length][image];
    # falls back to locating a known image signature if that layout doesn't fit.
    def get_tan_challenge_image
      binary = get_tan_challenge_binary
      return nil if binary.nil?
      b = binary.b
      if b.bytesize >= 4
        mime_len = (b.getbyte(0) << 8) | b.getbyte(1)
        header = 2 + mime_len + 2
        if mime_len.positive? && b.bytesize >= header
          img_len = (b.getbyte(2 + mime_len) << 8) | b.getbyte(3 + mime_len)
          img = b.byteslice(header, img_len)
          return img if img && !img.empty?
        end
      end
      %W[\x89PNG GIF8 \xff\xd8\xff].each do |sig|
        idx = b.index(sig.b)
        return b.byteslice(idx..-1) if idx
      end
      nil
    end

    # Human-readable "code: text" feedback across HIRMG (message) and HIRMS
    # (segment) feedback, e.g. "3010: Kontonummer ist ungültig.". Useful for
    # surfacing why an order returned nothing - banks often reject with a
    # warning-level (3xxx) code that #successful? deliberately ignores.
    def feedback_messages
      messages = []
      ['HIRMG', 'HIRMS'].each do |name|
        find_segments(name).each do |seg|
          split_for_data_groups(seg).drop(1).each do |dg|
            de = split_for_data_elements(dg)
            code = de[0]
            next if code.nil? || code.empty?
            text = Helper.fints_unescape(de[2].to_s).chomp("'")
            messages << (text.empty? ? code : "#{code}: #{text}")
          end
        end
      end
      messages
    end

    # All feedback codes across HIRMG (message) and HIRMS (segment) feedback.
    def return_codes
      codes = []
      ['HIRMG', 'HIRMS'].each do |name|
        find_segments(name).each do |seg|
          split_for_data_groups(seg).drop(1).each do |dg|
            code = split_for_data_elements(dg)[0]
            codes << code unless code.nil? || code.empty?
          end
        end
      end
      codes
    end

    # True when the bank explicitly reported that strong authentication is not
    # necessary for this operation (return code 3076). Authoritative - it
    # overrides any security-release code.
    def sca_not_required?
      !(return_codes & SCA_NOT_REQUIRED_CODES).empty?
    end

    # True when the bank asked for strong customer authentication (either a
    # security release or a pending decoupled approval).
    def sca_required?
      return false if sca_not_required?
      !(return_codes & (SCA_REQUIRED_CODES + SCA_PENDING_CODES)).empty?
    end

    # True while a decoupled authorisation is still awaiting app approval.
    def decoupled_pending?
      !(return_codes & SCA_PENDING_CODES).empty?
    end

    # True once strong authentication has been performed (or is no longer
    # pending).
    def sca_approved?
      return true unless (return_codes & SCA_APPROVED_CODES).empty?
      !decoupled_pending?
    end
    
    def unwrap(data)
      match = RE_UNWRAP.match(data)
      match ? match[1] : data
    end

    def find_segment(name)
      find_segments(name, one: true)
    end

    def find_segments(name, one: false)
      found = one ? nil : []
      @segments.each do |segment|
        spl = segment.split(':', 2)
        if spl[0] == name
          return segment if one
          found << segment
        end
      end
      found
    end
    
    def find_segment_for_reference(name, ref)
      segs = find_segments(name)
      segs.each do |seg|
        segsplit = split_for_data_elements(split_for_data_groups(seg)[0])
        return seg if segsplit[3] == ref.segmentno.to_s
      end
      nil
    end

    def get_touchdowns(msg)
      touchdown = {}
      msg.encrypted_segments.each do |msgseg|
        seg = find_segment_for_reference('HIRMS', msgseg)
        next unless seg
        parts = split_for_data_groups(seg).drop(1)
        parts.each do |p|
          psplit = split_for_data_elements(p)
          next if psplit[0] != '3040'
          td = psplit[3]
          next if td.nil?
          touchdown[msgseg.class] = Helper.fints_unescape(td)
        end
      end
      touchdown
    end
  end
end
