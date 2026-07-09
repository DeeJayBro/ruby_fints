module FinTS
  module Segment
    # HKVVB (Verarbeitungsvorbereitung)
    # Section C.3.1.3
    class HKVVB < BaseSegment
      LANG_DE = 1
      LANG_EN = 2
      LANG_FR = 3

      # +product_name+ is the "Produktbezeichnung". Since PSD2, banks require
      # this to be the registration number the product was assigned by the
      # Deutsche Kreditwirtschaft; unregistered products are rejected with
      # "9078 - Banking-Programm ist nicht registriert".
      #
      # +bpd_version+ / +upd_version+ tell the bank which bank/user parameter
      # data the client already holds (0 = none, so the bank sends the full
      # set). They should carry the versions the bank last reported in HIBPA /
      # HIUPA once those are known.
      def initialize(segment_no, lang: LANG_DE, product_name: FinTS::GEM_NAME, product_version: FinTS::VERSION,
                     bpd_version: 0, upd_version: 0)
        data = [bpd_version, upd_version, lang, Helper.fints_escape(product_name.to_s), Helper.fints_escape(product_version.to_s)]
        super(segment_no, data)
      end

      protected

      def type
        'HKVVB'
      end
      
      def version
        3
      end
    end
  end
end
