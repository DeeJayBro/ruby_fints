module FinTS
  class Client
    class << self
      attr_writer :logger

      def logger
        @logger ||= Logger.new($stdout).tap do |log|
          log.progname = self.name
        end
      end
    end

    def initialize
      @accounts = []
    end

    # Opens a ready-to-use dialog. The first time, it synchronises to obtain a
    # customer system ID (Kundensystem-ID) and the bank parameter data; on later
    # calls that state is reused, so no new customer system is registered.
    def open_dialog(check_bpd: false)
      dialog = new_dialog
      unless dialog_established?
        dialog.check_bpd if check_bpd
        dialog.sync
      end
      dialog.init
      remember_dialog(dialog)
      dialog
    end

    # Overridden by clients that persist the customer system ID / bank
    # parameter data between operations. The default always synchronises.
    def dialog_established?
      false
    end

    def remember_dialog(dialog); end

    # Whether the bank offers a securities depot listing (HKWPD). Known only
    # after the bank parameter data has been retrieved (e.g. after the first
    # get_sepa_accounts / get_balance).
    def holdings_available?
      false
    end

    # Number of days of CAMT transaction history the bank keeps available for
    # retrieval (the HICAZS "Speicherzeitraum"), or nil when unknown / not
    # advertised. Known only after the bank parameter data has been retrieved
    # (e.g. after the first get_sepa_accounts / get_balance).
    def camt_storage_days
      nil
    end

    def get_sepa_accounts
      dialog = open_dialog(check_bpd: true)

      msg_spa = new_message(dialog, [Segment::HKSPA.new(3, nil, nil, nil)])
      FinTS::Client.logger.debug("Sending HKSPA: #{msg_spa}")
      resp = dialog.send_msg(msg_spa)
      FinTS::Client.logger.debug("Got HKSPA response: #{resp}")
      dialog.send_end

      accounts = resp.find_segment('HISPA')
      raise SegmentNotFoundError, 'Could not find HISPA segment' if accounts.nil?
      accountlist = accounts.split('+').drop(1)
      @accounts = accountlist.map do |acc|
        arr = acc.split(':')
        {
          iban: arr[1],
          bic: arr[2],
          accountnumber: arr[3],
          subaccount: arr[4],
          blz: arr[6]
        }
      end
    end

    def get_balance(account)
      FinTS::Client.logger.info("Start fetching balance")

      dialog = open_dialog

      msg = create_balance_message(dialog, account)
      FinTS::Client.logger.debug("Send message: #{msg}")
      resp = dialog.send_msg(msg)
      # PSD2: the order carries an HKTAN; if the bank challenges, the balance is
      # delivered in the decoupled approval response.
      resp = dialog.complete_strong_authentication(resp)
      dialog.send_end

      # find segment and split up to balance part
      seg = resp.find_segment('HISAL')
      raise SegmentNotFoundError, 'Could not find HISAL segment' if seg.nil?
      arr = Helper.split_for_data_elements(Helper.split_for_data_groups(seg)[4])

      amount = arr[1].sub(',', '.').to_f
      # 'C' for credit, 'D' for debit
      amount *= -1 if arr[0] == 'D'

      balance = {
        amount: amount,
        currency: arr[2],
        date: Date.parse(arr[3])
      }

      FinTS::Client.logger.debug("Balance: #{balance}")
      balance
    end

    def create_balance_message(dialog, account)
      hversion = dialog.hksalversion
      segments = [Segment::HKSAL.new(3, hversion, account_identifier(account, hversion))]
      segments << strong_authentication_segment(dialog, 'HKSAL', 4)
      new_message(dialog, segments.compact)
    end

    # PSD2 process variant 2: a business order that requires strong
    # authentication must be accompanied by an HKTAN(4) segment naming the
    # order it authorises, otherwise the bank rejects it with
    # "9370 - Anzahl Signaturen für diesen Auftrag unzureichend". Conversely, an
    # order that needs no TAN (per the bank's HIPINS) must NOT carry one, or the
    # bank rejects it with "9010 - ... kann nicht verteilt signiert werden".
    # Returns nil when no HKTAN should be attached.
    def strong_authentication_segment(dialog, segment_id, segno)
      return nil unless dialog.strong_authentication?
      return nil unless dialog.tan_required?(segment_id)
      Segment::HKTAN.new(segno, dialog.hktanversion, '4', segment_id: segment_id)
    end

    # Serializes an account into the form a segment version expects: the
    # national account identification (Kontoverbindung) for versions below 7,
    # and the international one (Kontoverbindung international, IBAN/BIC) for
    # version 7 and up (7, 8, ...). Used by HKSAL and HKWPD, which share this
    # account element and each got a new SEPA version over time.
    def account_identifier(account, version)
      if version.to_i >= 7
        international_account_identifier(account)
      else
        [account[:accountnumber], account[:subaccount], '280', account[:blz]].join(':')
      end
    end

    # Kontoverbindung international (IBAN/BIC form). Used by HKSAL/HKWPD at
    # version 7+.
    def international_account_identifier(account)
      [account[:iban], account[:bic], account[:accountnumber], account[:subaccount], '280', account[:blz]].join(':')
    end

    # Account identification for CAMT (HKCAZ): The IBAN alone
    # uniquely identifies the account, so that is enough. Falls back to the full
    # international form on the (SEPA-era unlikely) chance there is no IBAN.
    def sepa_account_identifier(account)
      return international_account_identifier(account) if account[:iban].nil? || account[:iban].to_s.empty?
      [account[:iban], account[:bic]].join(':')
    end

    # Retrieves account transactions in the CAMT format (HKCAZ). The bank answers
    # with ISO 20022 camt.05x XML (in HICAZ segments), which is parsed into an
    # array of transaction hashes (see FinTS::CamtParser for the shape). Requires
    # the bank to advertise CAMT support (a camt descriptor in HICAZS); otherwise
    # a SegmentNotFoundError is raised.
    #
    # Also available under the alias #get_transactions.
    def get_statement(account, start_date, end_date)
      FinTS::Client.logger.info("Start fetching from #{start_date} to #{end_date}")

      dialog = open_dialog

      if dialog.camt_descriptor.nil?
        dialog.send_end
        raise SegmentNotFoundError,
              'Bank does not advertise CAMT statement support (no camt descriptor in HICAZS)'
      end

      msg = create_statement_message(dialog, account, start_date, end_date, nil)
      FinTS::Client.logger.debug("Send message: #{msg}")
      resp = dialog.send_msg(msg)
      resp = dialog.complete_strong_authentication(resp)
      touchdowns = resp.get_touchdowns(msg)
      responses = [resp]
      touchdown_counter = 1

      while touchdowns.include?(Segment::HKCAZ)
        FinTS::Client.logger.info("Fetching more results (#{touchdown_counter})...")
        msg = create_statement_message(dialog, account, start_date, end_date, touchdowns[Segment::HKCAZ])
        FinTS::Client.logger.debug("Send message: #{msg}")

        resp = dialog.send_msg(msg)
        responses << resp
        touchdowns = resp.get_touchdowns(msg)

        touchdown_counter += 1
      end

      FinTS::Client.logger.info('Fetching done.')
      statement = CamtParser.new.parse(camt_payload(responses))

      # A segment-level rejection (e.g. "3010 Kontonummer ist ungültig") is a
      # warning-level code that does not abort the dialog, so an empty result
      # would otherwise be silent. Surface the bank's feedback instead.
      if statement.empty?
        feedback = responses.flat_map(&:feedback_messages).uniq
        FinTS::Client.logger.warn("No transactions returned. Bank feedback: #{feedback.join(' | ')}") unless feedback.empty?
      end

      FinTS::Client.logger.debug("Statement: #{statement}")
      dialog.send_end
      statement
    end

    # The CAMT payload is a list of transactions, so expose the operation under
    # its transaction-oriented name too (matching python-fints' #get_transactions).
    alias_method :get_transactions, :get_statement

    # Concatenates the CAMT XML carried by every HICAZ segment across all
    # (paginated) responses. Each HICAZ delivers its transactions as a binary
    # data element prefixed with an '@<length>@' marker; the marker is stripped
    # and the raw XML kept so the parser can recover each <Document>.
    def camt_payload(responses)
      re_data = /^[^@]*@([0-9]+?)@(.+)/m
      payload = +''
      responses.each do |r|
        r.find_segments('HICAZ').each do |seg|
          match = re_data.match(seg)
          next unless match
          payload << match[2]
        end
      end
      payload
    end

    def create_statement_message(dialog, account, start_date, end_date, touchdown)
      hversion = dialog.hkcazversion
      acc = sepa_account_identifier(account)
      segments = [Segment::HKCAZ.new(3, hversion, acc, dialog.camt_descriptor, start_date, end_date, touchdown)]
      # Only the initial request needs SCA; continuation (touchdown) requests
      # run inside the already-authenticated dialog.
      segments << strong_authentication_segment(dialog, 'HKCAZ', 4) if touchdown.nil?
      new_message(dialog, segments.compact)
    end

    def get_holdings(account)
      FinTS::Client.logger.info('Start fetching holdings')

      # init dialog (synchronises once, then reuses the customer system ID)
      dialog = open_dialog

      # execute job
      msg = create_get_holdings_message(dialog, account)
      FinTS::Client.logger.debug("Sending HKWPD: #{msg}")
      resp = dialog.send_msg(msg)
      resp = dialog.complete_strong_authentication(resp)
      FinTS::Client.logger.debug("Got HIWPD response: #{resp}")

      # end dialog
      dialog.send_end

      holdings = holdings_from_response(resp)
      FinTS::Client.logger.debug("Holdings: #{holdings}")
      holdings
    end

    # Extracts the securities holdings from a (already received) response.
    # A response may contain more than one HIWPD segment; the MT535 payload
    # of each is parsed and the results are concatenated.
    def holdings_from_response(resp)
      segments = resp.find_segments('HIWPD')
      if segments.nil? || segments.empty?
        FinTS::Client.logger.warn('No HIWPD response segment found - maybe account has no holdings?')
        return []
      end

      parser = MT535Miniparser.new
      segments.flat_map do |seg|
        parser.parse(extract_mt535_lines(seg))
      end
    end

    # A HIWPD segment carries the MT535 message as a binary data element,
    # prefixed with an '@<length>@' marker. Strip the segment header and the
    # marker, then split the payload into individual (CR/LF-free) MT535 lines.
    def extract_mt535_lines(segment)
      match = /@\d+@(.+)/m.match(segment)
      payload = match ? match[1] : segment
      payload.split(/\r?\n/).map(&:strip).reject(&:empty?)
    end

    def create_get_holdings_message(dialog, account)
      hversion = dialog.hkwpdversion
      acc = account_identifier(account, hversion)
      segments = [Segment::HKWPD.new(3, hversion, acc), strong_authentication_segment(dialog, 'HKWPD', 4)]
      new_message(dialog, segments.compact)
    end
  end
end
