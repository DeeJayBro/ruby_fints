require 'rexml/document'
require 'date'

module FinTS
  # Parses camt.052 / camt.053 (ISO 20022 "Bank-to-Customer Account Report /
  # Statement") documents as delivered inside HICAZ segments when account
  # transactions are requested via HKCAZ. It is the CAMT replacement for the
  # MT940 parsing that HKKAZ used to rely on.
  #
  # The parser is namespace-agnostic: it matches elements by their local name,
  # so it copes with the various camt versions banks emit (…052.001.02,
  # …052.001.08, …053.001.02, …) without hard-coding a namespace.
  #
  # Each transaction (one per <Ntry>) is returned as a hash. The commonly used
  # values are lifted to convenient top-level keys, but CAMT is far richer than
  # those few fields, so the *complete*, loss-free representation of the entry is
  # always available under :raw (a nested Hash mirroring the XML: repeated
  # elements become arrays, attributes are stored under "@name" keys and mixed
  # text under "#text"). Nothing the bank sent is discarded.
  #
  #   {
  #     amount:           -12.5,          # signed: negative = debit (money out)
  #     currency:         'EUR',
  #     status:           'BOOK',         # raw entry status (BOOK / PDNG / INFO / …)
  #     booked:           true,           # convenience: status == 'BOOK'
  #     booking_date:     #<Date …>,
  #     value_date:       #<Date …>,
  #     name:             'Stadtwerke',   # the other party
  #     iban:             'DE02…',        # the other party's IBAN (nil if absent)
  #     bic:              'GENODEF1…',    # the other party's agent BIC (nil if absent)
  #     purpose:          'Strom Januar', # unstructured remittance information
  #     end_to_end_id:    'NOTPROVIDED',
  #     mandate_id:       'M-2023-1',
  #     creditor_id:      'DE98ZZZ…',     # SEPA creditor identifier
  #     reference:        'ACCTSVCR-1',   # account servicer reference
  #     additional_info:  'SEPA GUTSCHRIFT',
  #     transaction_code: '177',          # bank transaction / GVC code
  #     raw:              { … }           # the whole <Ntry>, nothing dropped
  #   }
  class CamtParser
    def parse(xml)
      return [] if xml.nil? || xml.to_s.strip.empty?
      split_documents(xml).flat_map { |doc_xml| parse_document(doc_xml) }
    end

    # A HICAZ payload can concatenate several camt documents (e.g. one per
    # booking day), each with its own <Document> root and XML declaration.
    def split_documents(xml)
      xml.scan(%r{<(?:\w+:)?Document\b.*?</(?:\w+:)?Document>}m)
    end

    private

    def parse_document(doc_xml)
      doc = REXML::Document.new(doc_xml)
      return [] if doc.root.nil?
      find_all(doc.root, 'Ntry').map { |ntry| parse_entry(ntry) }
    end

    def parse_entry(ntry)
      credit = text(child(ntry, 'CdtDbtInd')) == 'CRDT'
      amount = to_amount(text(child(ntry, 'Amt')))
      amount = -amount if amount && !credit

      status = status_code(ntry)
      details = descend(child(ntry, 'NtryDtls'), 'TxDtls')
      name, iban = counterparty(details, credit)

      {
        amount: amount,
        currency: attribute(child(ntry, 'Amt'), 'Ccy'),
        status: status,
        booked: status == 'BOOK',
        booking_date: date_of(child(ntry, 'BookgDt')),
        value_date: date_of(child(ntry, 'ValDt')),
        name: name,
        iban: iban,
        bic: counterparty_bic(ntry, credit),
        purpose: remittance(details),
        end_to_end_id: text(descend(ntry, 'EndToEndId')),
        mandate_id: text(descend(ntry, 'MndtId')),
        creditor_id: leaf_text(descend(ntry, 'CdtrSchmeId')),
        reference: text(descend(ntry, 'AcctSvcrRef')),
        additional_info: additional_info(ntry),
        transaction_code: transaction_code(child(ntry, 'BkTxCd')),
        # Complete, loss-free view of the entry so no CAMT metadata is thrown
        # away, whatever version/fields the bank used.
        raw: element_to_h(ntry)
      }
    end

    # Entry status code: 'BOOK' (booked) vs 'PDNG' (pending) vs 'INFO'. camt
    # …001.08 nests it as <Sts><Cd>BOOK</Cd></Sts>; earlier versions put the code
    # directly in <Sts>.
    def status_code(ntry)
      sts = child(ntry, 'Sts')
      code = text(sts)
      code = text(descend(sts, 'Cd')) if code.nil? || code.empty?
      code
    end

    # For a credit the interesting party is the debtor (who paid us); for a debit
    # it is the creditor (whom we paid). Returns [name, iban].
    def counterparty(txdtls, credit)
      return [nil, nil] if txdtls.nil?
      rltd = descend(txdtls, 'RltdPties')
      return [nil, nil] if rltd.nil?
      party = descend(rltd, credit ? 'Dbtr' : 'Cdtr')
      acct  = descend(rltd, credit ? 'DbtrAcct' : 'CdtrAcct')
      [text(descend(party, 'Nm')), text(descend(acct, 'IBAN'))]
    end

    # The other party's agent BIC (…001.08 uses <BICFI>, earlier versions <BIC>).
    def counterparty_bic(ntry, credit)
      agent = descend(ntry, credit ? 'DbtrAgt' : 'CdtrAgt')
      return nil if agent.nil?
      text(descend(agent, 'BICFI')) || text(descend(agent, 'BIC'))
    end

    def remittance(txdtls)
      return nil if txdtls.nil?
      rmt = descend(txdtls, 'RmtInf')
      return nil if rmt.nil?
      join(find_all(rmt, 'Ustrd').map { |u| text(u) })
    end

    def additional_info(ntry)
      join(find_all(ntry, 'AddtlNtryInf').map { |e| text(e) } +
           find_all(ntry, 'AddtlTxInf').map { |e| text(e) })
    end

    # Prefer the proprietary bank transaction code (often the German GVC, e.g.
    # '166'); fall back to the ISO domain code.
    def transaction_code(bktxcd)
      return nil if bktxcd.nil?
      code = text(descend(descend(bktxcd, 'Prtry'), 'Cd'))
      return code if code && !code.empty?
      text(descend(descend(bktxcd, 'Domn'), 'Cd'))
    end

    def date_of(element)
      return nil if element.nil?
      to_date(text(descend(element, 'Dt')) || text(descend(element, 'DtTm')))
    end

    # --- generic, loss-free XML -> Hash ----------------------------------------

    # Converts an element into a nested structure that preserves everything:
    #   * a leaf element becomes its text,
    #   * attributes are kept under "@name" keys,
    #   * mixed text alongside children/attributes is kept under "#text",
    #   * repeated child element names collapse into arrays.
    # Namespace (xmlns) declarations are dropped as they carry no data.
    def element_to_h(element)
      children = element.elements.to_a
      attributes = data_attributes(element)
      return text(element) if children.empty? && attributes.empty?

      result = {}
      attributes.each { |name, value| result["@#{name}"] = value }
      own = text(element)
      result['#text'] = own if own && !own.empty?
      children.each do |child|
        key = child.name
        value = element_to_h(child)
        if result.key?(key)
          result[key] = [result[key]] unless result[key].is_a?(Array)
          result[key] << value
        else
          result[key] = value
        end
      end
      result
    end

    def data_attributes(element)
      attrs = {}
      element.attributes.each_attribute do |a|
        next if a.name == 'xmlns' || a.prefix == 'xmlns'
        attrs[a.name] = a.value
      end
      attrs
    end

    # --- element traversal (namespace-agnostic, by local name) -----------------

    # First direct child element with the given local name.
    def child(node, name)
      return nil if node.nil?
      node.elements.each { |e| return e if e.name == name }
      nil
    end

    # First descendant element (depth-first) with the given local name.
    def descend(node, name)
      return nil if node.nil?
      node.elements.each do |e|
        return e if e.name == name
        found = descend(e, name)
        return found if found
      end
      nil
    end

    # All descendant elements with the given local name.
    def find_all(node, name, acc = [])
      return acc if node.nil?
      node.elements.each do |e|
        acc << e if e.name == name
        find_all(e, name, acc)
      end
      acc
    end

    # Text of the element, or of its first text-bearing descendant (for values
    # wrapped in identifier scaffolding like CdtrSchmeId/Id/PrvtId/Othr/Id).
    def leaf_text(element)
      return nil if element.nil?
      own = text(element)
      return own if own && !own.empty?
      element.elements.each do |child|
        found = leaf_text(child)
        return found if found
      end
      nil
    end

    def text(element)
      return nil if element.nil?
      t = element.text
      t.nil? ? nil : t.strip
    end

    def attribute(element, name)
      element.nil? ? nil : element.attributes[name]
    end

    def join(values)
      parts = values.reject { |t| t.nil? || t.empty? }
      parts.empty? ? nil : parts.join(' ')
    end

    def to_amount(str)
      return nil if str.nil? || str.empty?
      str.to_f
    end

    def to_date(str)
      return nil if str.nil? || str.empty?
      Date.parse(str)
    rescue ArgumentError
      nil
    end
  end
end
