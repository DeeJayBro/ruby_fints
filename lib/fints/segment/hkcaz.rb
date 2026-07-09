module FinTS
  module Segment
    # HKCAZ (Kontoumsätze im camt-Format anfordern/Zeitraum)
    # The CAMT counterpart of HKKAZ: it requests account transactions but the
    # bank answers with ISO 20022 camt.05x XML (in HICAZ) instead of MT940.
    # Refs: FinTS 3.0 Messages_Geschaeftsvorfaelle, section C.2.1.1.1.4
    #
    # Unlike HKKAZ it always carries the international account identification
    # (IBAN/BIC) and a camt descriptor naming the message format the client
    # wants (echoed back from the bank's HICAZS advertisement).
    class HKCAZ < BaseSegment
      def initialize(segno, version, account, camt_descriptor, date_start, date_end, touchdown)
        @version = version
        data = [
          account,
          # the descriptor is a URN whose own colons would otherwise be read as
          # data-element separators, so it must be escaped.
          camt_descriptor ? Helper.fints_escape(camt_descriptor) : '',
          'N',
          date_start.strftime('%Y%m%d'),
          date_end.strftime('%Y%m%d'),
          '',
          touchdown ? Helper.fints_escape(touchdown) : ''
        ]
        super(segno, data)
      end

      protected

      def type
        'HKCAZ'
      end

      def version
        @version
      end
    end
  end
end
