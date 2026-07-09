module FinTS
  class DialogError < StandardError; end

  class Dialog
    attr_accessor :system_id
    attr_accessor :dialog_id
    attr_accessor :msg_no
    attr_accessor :tan_mechs
    attr_accessor :hkcazversion
    attr_accessor :hksalversion
    attr_accessor :hkwpdversion
    attr_accessor :hktanversion
    attr_accessor :tan_methods
    attr_accessor :holdings_supported
    attr_accessor :camt_descriptors

    def initialize(blz, username, pin, system_id, connection, product_name: FinTS::GEM_NAME, product_version: FinTS::VERSION,
                   tan_mechanism: nil, tan_medium: nil, poll_interval: 5, max_poll_attempts: 60, tan_handler: nil)
      @blz = blz
      @username = username
      @pin = pin
      @system_id = system_id
      @connection = connection
      @product_name = product_name
      @product_version = product_version
      @preferred_tan_mechanism = tan_mechanism
      @tan_medium = tan_medium
      @poll_interval = poll_interval
      @max_poll_attempts = max_poll_attempts
      @tan_handler = tan_handler
      @msg_no = 1
      @dialog_id = 0
      @hksalversion = 6
      @hkcazversion = 1
      @hkwpdversion = 6
      @hktanversion = 6
      @bpd_version = 0
      @upd_version = 0
      @tan_mechs = []
      @tan_methods = []
      @tan_requirements = {}
      @holdings_supported = false
      @camt_descriptors = []
    end

    # The camt message format to request in HKCAZ, chosen from what the bank
    # advertised in HICAZS. Prefer a camt.052 descriptor (Bank-to-Customer
    # Account Report, i.e. account transactions); otherwise use the first one.
    # Returns nil when the bank does not offer CAMT statements at all.
    def camt_descriptor
      return nil if @camt_descriptors.nil? || @camt_descriptors.empty?
      @camt_descriptors.find { |d| d.include?('camt.052') } || @camt_descriptors.first
    end

    # Whether a business order for +segment_id+ (e.g. 'HKWPD') must carry a TAN,
    # per the bank's HIPINS parameters. Unknown operations default to true, so
    # a required TAN is never silently dropped.
    def tan_required?(segment_id)
      @tan_requirements.fetch(segment_id.to_s, true)
    end

    # Snapshot of everything learned during synchronisation (customer system ID
    # and bank parameter data) so a client can persist it and hand it to a later
    # dialog via #restore, avoiding a fresh sync (and a new customer system).
    def parameters
      {
        system_id: @system_id,
        bank_name: @bankname,
        tan_mechs: @tan_mechs,
        tan_methods: @tan_methods,
        hksalversion: @hksalversion,
        hkcazversion: @hkcazversion,
        hkwpdversion: @hkwpdversion,
        hktanversion: @hktanversion,
        bpd_version: @bpd_version,
        upd_version: @upd_version,
        tan_requirements: @tan_requirements,
        holdings_supported: @holdings_supported,
        camt_descriptors: @camt_descriptors
      }
    end

    # Seed the dialog with previously synchronised state so it can go straight
    # to #init without another #sync.
    def restore(params)
      return unless params
      @system_id = params[:system_id] if params[:system_id]
      @bankname = params[:bank_name]
      @tan_mechs = params[:tan_mechs] if params.key?(:tan_mechs)
      @tan_methods = params[:tan_methods] if params.key?(:tan_methods)
      @hksalversion = params[:hksalversion] if params[:hksalversion]
      @hkcazversion = params[:hkcazversion] if params[:hkcazversion]
      @hkwpdversion = params[:hkwpdversion] if params[:hkwpdversion]
      @hktanversion = params[:hktanversion] if params[:hktanversion]
      @bpd_version = params[:bpd_version] if params[:bpd_version]
      @upd_version = params[:upd_version] if params[:upd_version]
      @tan_requirements = params[:tan_requirements] if params[:tan_requirements]
      @holdings_supported = params[:holdings_supported] if params.key?(:holdings_supported)
      @camt_descriptors = params[:camt_descriptors] if params.key?(:camt_descriptors)
    end

    # HKVVB carrying the product identification and the currently known bank/user
    # parameter data versions (0/0 until the bank first reports them).
    def hkvvb_segment(segno)
      Segment::HKVVB.new(segno,
                         product_name: @product_name, product_version: @product_version,
                         bpd_version: @bpd_version, upd_version: @upd_version)
    end

    # Remember the BPD/UPD versions the bank reported so later messages can
    # supply them. Keeps the previous value when a response omits the segment.
    def update_bpd_upd_versions(resp)
      bpd = resp.get_bpd_version
      upd = resp.get_upd_version
      @bpd_version = bpd if bpd > 0
      @upd_version = upd if upd > 0
    end

    # Learn every bank/user parameter datum a response carries. Each field is
    # updated only when its segment is actually present, so a response that
    # omits the BPD - which happens once we advertise a matching BPD version, or
    # in the anonymous vs. authenticated dialog - never resets what an earlier
    # response already taught us (e.g. the HKTAN version from HITANS).
    def read_parameters(resp)
      name = resp.get_bank_name
      @bankname = name if name
      @hksalversion = resp.get_hksal_max_version if resp.find_segment('HISALS')
      if resp.find_segment('HICAZS')
        @hkcazversion = resp.get_hkcaz_max_version
        descriptors = resp.get_camt_descriptors
        @camt_descriptors = descriptors unless descriptors.empty?
      end
      if resp.find_segment('HIWPDS')
        @hkwpdversion = resp.get_hkwpd_max_version
        @holdings_supported = true # bank offers a securities depot listing (HKWPD)
      end
      @hktanversion = resp.get_hktan_max_version if resp.find_segment('HITANS')
      mechs = resp.get_supported_tan_mechanisms
      @tan_mechs = mechs if mechs
      methods = resp.get_tan_methods
      @tan_methods = methods unless methods.empty?
      reqs = resp.get_tan_requirements
      @tan_requirements = reqs unless reqs.empty?
      update_bpd_upd_versions(resp)
      prefer_tan_mechanism!
    end

    def sync
      FinTS::Client.logger.info('Initialize SYNC')

      seg_identification = Segment::HKIDN.new(3, @blz, @username, 0)
      seg_prepare = hkvvb_segment(4)
      seg_sync = Segment::HKSYN.new(5)

      msg_sync = Message.new(@blz, @username, @pin, @system_id, @dialog_id, @msg_no, [
        seg_identification,
        seg_prepare,
        seg_sync
      ])

      FinTS::Client.logger.debug("Sending SYNC: #{msg_sync}")
      resp = send_msg(msg_sync)
      FinTS::Client.logger.debug("Got SYNC response: #{resp}")
      @system_id = resp.get_system_id
      @dialog_id = resp.get_dialog_id
      read_parameters(resp)

      FinTS::Client.logger.debug("Bank name: #{@bankname}")
      FinTS::Client.logger.debug("System ID: #{@system_id}")
      FinTS::Client.logger.debug("Dialog ID: #{@dialog_id}")
      FinTS::Client.logger.debug("HKCAZ max version: #{@hkcazversion}")
      FinTS::Client.logger.debug("camt descriptors: #{@camt_descriptors}")
      FinTS::Client.logger.debug("HKSAL max version: #{@hksalversion}")
      FinTS::Client.logger.debug("HKWPD max version: #{@hkwpdversion}")
      FinTS::Client.logger.debug("HKTAN max version: #{@hktanversion}")
      FinTS::Client.logger.debug("TAN mechanisms: #{@tan_mechs}")
      FinTS::Client.logger.debug("TAN methods: #{@tan_methods}")
      send_end
    end

    # Move a caller-preferred two-step TAN mechanism to the front so it is the
    # one used for signing (Message signs with the first entry).
    def prefer_tan_mechanism!
      return unless @tan_mechs.is_a?(Array) && @preferred_tan_mechanism
      return unless @tan_mechs.include?(@preferred_tan_mechanism)
      @tan_mechs = [@preferred_tan_mechanism] + (@tan_mechs - [@preferred_tan_mechanism])
    end

    def check_bpd
      FinTS::Client.logger.info('Initialize BPD retrieval')

      seg_identification = Segment::HKIDN.new(3, @blz, "9999999999", 0, 0)
      seg_prepare = hkvvb_segment(4)

      msg_sync = Message.new(@blz, @username, @pin, @system_id, 0, 1, [
        seg_identification,
        seg_prepare,
      ], skip_signature: true)

      FinTS::Client.logger.debug("Sending ANONYMOUS DIALOG INIT: #{msg_sync}")
      resp = send_msg(msg_sync)
      FinTS::Client.logger.debug("Got INIT response: #{resp}")
      # The anonymous BPD retrieval already carries the full bank parameter data
      # (HITANS, HISALS, ...); learn it here so a later BPD-skipping sync cannot
      # lose it.
      read_parameters(resp)

      send_end
    end

    def init
      FinTS::Client.logger.info('Initialize Dialog')
      seg_identification = Segment::HKIDN.new(3, @blz, @username, @system_id)
      seg_prepare = hkvvb_segment(4)

      segments = [seg_identification, seg_prepare]
      # PSD2: signal strong-customer-authentication capability by requesting SCA
      # for the dialog identification (HKIDN) using HKTAN process variant 2.
      # Without this, PSD2-enforcing banks abort with
      # "9075 - Banking-Programm nicht PSD2-fähig".
      if strong_authentication?
        segments << Segment::HKTAN.new(5, @hktanversion, '4', segment_id: 'HKIDN', tan_medium: @tan_medium)
      end

      msg_init = Message.new(@blz, @username, @pin, @system_id, @dialog_id, @msg_no, segments, @tan_mechs)
      FinTS::Client.logger.debug("Sending INIT: #{msg_init}")
      resp = send_msg(msg_init)
      FinTS::Client.logger.debug("Got INIT response: #{resp}")

      @dialog_id = resp.get_dialog_id
      FinTS::Client.logger.info("Received dialog ID: #{@dialog_id}")
      read_parameters(resp)

      complete_strong_authentication(resp)

      @dialog_id
    end

    # True when the bank offers a genuine two-step TAN mechanism (i.e. anything
    # other than the single-step 999 procedure), meaning HKTAN must be sent.
    def strong_authentication?
      @tan_mechs.is_a?(Array) && @tan_mechs.any? { |m| m != '999' }
    end

    # After an HKTAN(4) submission (dialog init or a business order), drive the
    # decoupled ("app approval") authorisation to completion by polling the bank
    # until the user confirms it in their banking app. Returns the response that
    # carries the outcome: the original one when no challenge was raised (e.g.
    # operations covered by the PSD2 90-day exemption), otherwise the final poll
    # response, which also contains the executed order's result segments.
    def complete_strong_authentication(resp)
      if resp.sca_not_required?
        FinTS::Client.logger.debug('Bank reports strong authentication is not necessary (3076)')
        return resp
      end
      return resp unless resp.sca_required?

      order_ref = resp.get_tan_order_reference
      if order_ref.nil? || order_ref.empty?
        raise DialogError, 'Strong authentication required but the bank returned no order reference'
      end

      # An image in the challenge means a challenge/response method (e.g.
      # photoTAN); otherwise the bank uses decoupled ("app approval") and we
      # poll until the user confirms it.
      if resp.get_tan_challenge_image
        submit_challenge_tan(resp, order_ref)
      else
        poll_decoupled(order_ref)
      end
    end

    # Ask the configured tan_handler for the TAN that answers the bank's
    # challenge, then submit it with HKTAN(2). Returns the response, which
    # carries the executed order's result once the TAN is accepted.
    def submit_challenge_tan(resp, order_ref)
      unless @tan_handler
        raise DialogError, 'Strong authentication requires a TAN, but no tan_handler was configured ' \
                           'and the bank did not offer decoupled (app) approval'
      end

      challenge = {
        text: resp.get_tan_challenge,
        image: resp.get_tan_challenge_image,
        order_ref: order_ref
      }
      FinTS::Client.logger.info("Strong authentication required: #{challenge[:text]}")
      tan = @tan_handler.call(challenge)
      raise DialogError, 'No TAN was supplied for the challenge' if tan.nil? || tan.to_s.strip.empty?

      seg = Segment::HKTAN.new(3, @hktanversion, '2', order_ref: order_ref)
      msg = Message.new(@blz, @username, @pin, @system_id, @dialog_id, @msg_no, [seg], @tan_mechs,
                        tan: tan.to_s.strip)
      FinTS::Client.logger.debug('Submitting TAN')
      send_msg(msg)
    end

    def poll_decoupled(order_ref)
      FinTS::Client.logger.info('Waiting for decoupled strong authentication - please approve it in your banking app...')
      attempts = 0
      loop do
        attempts += 1
        if attempts > @max_poll_attempts
          raise DialogError, "Decoupled strong authentication was not approved after #{@max_poll_attempts} attempts"
        end
        wait_before_poll

        seg = Segment::HKTAN.new(3, @hktanversion, 'S', order_ref: order_ref)
        msg = Message.new(@blz, @username, @pin, @system_id, @dialog_id, @msg_no, [seg], @tan_mechs)
        resp = send_msg(msg)
        unless resp.decoupled_pending?
          FinTS::Client.logger.info('Decoupled strong authentication approved.')
          return resp
        end
        FinTS::Client.logger.debug("Authentication still pending (attempt #{attempts}/#{@max_poll_attempts})...")
      end
    end

    def wait_before_poll
      sleep(@poll_interval) if @poll_interval && @poll_interval > 0
    end

    def send_msg(msg)
      FinTS::Client.logger.info('Sending Message')
      msg.msg_no = @msg_no
      msg.dialog_id = @dialog_id

      resp = Response.new(@connection.send_msg(msg))
      if !resp.successful?
        raise DialogError, resp.get_summary_by_segment('HIRMG')
      end
      @msg_no += 1
      resp
    end

    def send_end
      FinTS::Client.logger.info('Initialize END')

      msg_end = Message.new(@blz, @username, @pin, @system_id, @dialog_id, @msg_no, [
        Segment::HKEND.new(3, @dialog_id)
      ])
      FinTS::Client.logger.debug("Sending END: #{msg_end}")
      resp = send_msg(msg_end)
      FinTS::Client.logger.debug("Got END response: #{resp}")
      FinTS::Client.logger.info('Resetting dialog ID and message number count')
      @dialog_id = 0
      @msg_no = 1
      resp
    end
  end
end
