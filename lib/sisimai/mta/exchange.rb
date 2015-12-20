module Sisimai
  module MTA
    # Sisimai::MTA::Exchange parses a bounce email which created by Microsoft
    # Exchange Server. Methods in the module are called from only Sisimai::Message.
    module Exchange
      # Imported from p5-Sisimail/lib/Sisimai/MTA/Exchange.pm
      class << self
        require 'sisimai/mta'
        require 'sisimai/rfc5322'

        Re0 = {
          # X-Mailer: Internet Mail Service (5.0.1461.28)
          # X-Mailer: Microsoft Exchange Server Internet Mail Connector Version ...
          :'x-mailer'  => %r{\A(?:
             Internet[ ]Mail[ ]Service[ ][(][\d.]+[)]\z
            |Microsoft[ ]Exchange[ ]Server[ ]Internet[ ]Mail[ ]Connector
            )
          }x,
          :'x-mimeole' => %r/\AProduced By Microsoft Exchange/,
          # Received: by ***.**.** with Internet Mail Service (5.5.2657.72)
          :'received'  => %r/\Aby .+ with Internet Mail Service [(][\d.]+[)]/,
        }
        Re1 = {
          :begin  => %r/\AYour message/,
          :error  => %r/\Adid not reach the following recipient[(]s[)]:/,
          :rfc822 => %r|\AContent-Type: message/rfc822|,
          :endof  => %r/\A__END_OF_EMAIL_MESSAGE__\z/,
        }
        ErrorCodeTable = {
          'onhold' => [
              '000B099C', # Host Unknown, Message exceeds size limit, ...
              '000B09AA', # Unable to relay for, Message exceeds size limit,...
              '000B09B6', # Error messages by remote MTA
          ],
          'userunknown' => [
              '000C05A6', # Unknown Recipient,
          ],
          'systemerror' => [
              '00010256', # Too many recipients. 
              '000D06B5', # No proxy for recipient (non-smtp mail?)
          ],
          'networkerror' => [
              '00120270', # Too Many Hops
          ],
          'contenterr' => [
              '00050311', # Conversion to Internet format failed
              '000502CC', # Conversion to Internet format failed
          ],
          'securityerr' => [
              '000B0981', # 502 Server does not support AUTH
          ],
          'filtered' => [
              '000C0595', # Ambiguous Recipient
          ],
        }
        Indicators = Sisimai::MTA.INDICATORS
        LongFields = Sisimai::RFC5322.LONGFIELDS
        RFC822Head = Sisimai::RFC5322.HEADERFIELDS

        def description; return 'Microsoft Exchange Server'; end
        def smtpagent;   return 'Exchange'; end
        def headerlist;  return [ 'X-MS-Embedded-Report', 'X-MimeOLE' ]; end
        def pattern;     return Re0; end

        # Parse bounce messages from Microsoft Exchange Server
        # @param         [Hash] mhead       Message header of a bounce email
        # @options mhead [String] from      From header
        # @options mhead [String] date      Date header
        # @options mhead [String] subject   Subject header
        # @options mhead [Array]  received  Received headers
        # @options mhead [String] others    Other required headers
        # @param         [String] mbody     Message body of a bounce email
        # @return        [Hash, Nil]        Bounce data list and message/rfc822
        #                                   part or nil if it failed to parse or
        #                                   the arguments are missing
        def scan(mhead, mbody)
          return nil unless mhead
          return nil unless mbody
          match = 0

          match += 1 if mhead['x-ms-embedded-report']
          catch :EXCHANGE_OR_NOT do
            loop do
              throw :EXCHANGE_OR_NOT if match > 0

              if mhead['x-mailer']
                # X-Mailer:  Microsoft Exchange Server Internet Mail Connector Version 4.0.994.63
                # X-Mailer: Internet Mail Service (5.5.2232.9)
                match += 1 if mhead['x-mailer'] =~ Re0[:'x-mailer']
                throw :EXCHANGE_OR_NOT if match > 0
              end

              if mhead['x-mimeole']
                # X-MimeOLE: Produced By Microsoft Exchange V6.5
                match += 1 if mhead['x-mimeole'] =~ Re0['x-mimeole']
                throw :EXCHANGE_OR_NOT if match > 0
              end

              throw :EXCHANGE_OR_NOT if mhead['received'].size == 0
              mhead['received'].each do |e|
                # Received: by ***.**.** with Internet Mail Service (5.5.2657.72)
                next unless e =~ Re0[:'received']
                match += 1
                throw :EXCHANGE_OR_NOT
              end
              break
            end
          end
          return nil if match == 0

          dscontents = []; dscontents << Sisimai::MTA.DELIVERYSTATUS
          hasdivided = mbody.split("\n")
          havepassed = [''];
          rfc822next = { 'from' => false, 'to' => false, 'subject' => false }
          rfc822part = ''     # (String) message/rfc822-headers part
          previousfn = ''     # (String) Previous field name
          readcursor = 0      # (Integer) Points the current cursor position
          recipients = 0      # (Integer) The number of 'Final-Recipient' header
          statuspart = false  # (Boolean) Flag, true = have got delivery status part.
          connvalues = 0      # (Integer) Flag, 1 if all the value of $connheader have been set
          connheader = {
            'to'      => '',  # The value of "To"
            'date'    => '',  # The value of "Date"
            'subject' => '',  # The value of "Subject"
          }
          v = nil

          hasdivided.each do |e|
            # Save the current line for the next loop
            havepassed << e; p = havepassed[-2]

            if readcursor == 0
              # Beginning of the bounce message or delivery status part
              if e =~ Re1[:begin]
                readcursor |= Indicators[:'deliverystatus']
                next
              end
            end

            if readcursor & Indicators[:'message-rfc822'] == 0
              # Beginning of the original message part
              if e =~ Re1[:rfc822]
                readcursor |= Indicators[:'message-rfc822']
                next
              end
            end

            if readcursor & Indicators[:'message-rfc822'] > 0
              # After "message/rfc822"
              if cv = e.match(/\A([-0-9A-Za-z]+?)[:][ ]*.+\z/)
                # Get required headers only
                lhs = cv[1].downcase
                previousfn = '';
                next unless RFC822Head.key?(lhs)

                previousfn  = lhs
                rfc822part += e + "\n"

              elsif e =~ /\A\s+/
                # Continued line from the previous line
                next if rfc822next[previousfn]
                rfc822part += e + "\n" if LongFields.key?(previousfn)

              else
                # Check the end of headers in rfc822 part
                next unless LongFields.key?(previousfn)
                next unless e.empty?
                rfc822next[previousfn] = true
              end

            else
              # Before "message/rfc822"
              next if readcursor & Indicators[:'deliverystatus'] == 0
              next if statuspart

              if connvalues == connheader.keys.size
                # did not reach the following recipient(s):
                # 
                # kijitora@example.co.jp on Thu, 29 Apr 2007 16:51:51 -0500
                #     The recipient name is not recognized
                #     The MTS-ID of the original message is: c=jp;a= ;p=neko
                # ;l=EXCHANGE000000000000000000
                #     MSEXCH:IMS:KIJITORA CAT:EXAMPLE:EXCHANGE 0 (000C05A6) Unknown Recipient
                # mikeneko@example.co.jp on Thu, 29 Apr 2007 16:51:51 -0500
                #     The recipient name is not recognized
                #     The MTS-ID of the original message is: c=jp;a= ;p=neko
                # ;l=EXCHANGE000000000000000000
                #     MSEXCH:IMS:KIJITORA CAT:EXAMPLE:EXCHANGE 0 (000C05A6) Unknown Recipient
                v = dscontents[-1]

                if cv = e.match(/\A\s*([^ ]+[@][^ ]+) on\s*.*\z/) ||
                   cv = e.match(/\A\s*.+(?:SMTP|smtp)=([^ ]+[@][^ ]+) on\s*.*\z/)
                  # kijitora@example.co.jp on Thu, 29 Apr 2007 16:51:51 -0500
                  #   kijitora@example.com on 4/29/99 9:19:59 AM
                  if v['recipient']
                    # There are multiple recipient addresses in the message body.
                    dscontents << Sisimai::MTA.DELIVERYSTATUS
                    v = dscontents[-1]
                  end
                  v['recipient'] = cv[1]
                  v['msexch'] = false
                  recipients += 1

                elsif cv = e.match(/\A\s+(MSEXCH:.+)\z/)
                  #     MSEXCH:IMS:KIJITORA CAT:EXAMPLE:EXCHANGE 0 (000C05A6) Unknown Recipient
                  v['diagnosis'] ||= ''
                  v['diagnosis']  += cv[1]

                else
                  next if v['msexch']
                  if v['diagnosis'] =~ /\AMSEXCH:.+/
                    # Continued from MEEXCH in the previous line
                    v['msexch'] = true
                    v['diagnosis'] ||= ''
                    v['diagnosis']  += ' ' + e
                    statuspart = true

                  else
                    # Error message in the body part
                    v['alterrors'] ||= ''
                    v['alterrors']  += ' ' + e
                  end
                end

              else
                # Your message
                #
                #  To:      shironeko@example.jp
                #  Subject: ...
                #  Sent:    Thu, 29 Apr 2010 18:14:35 +0000
                #
                if cv = e.match(/\A\s+To:\s+(.+)\z/)
                  #  To:      shironeko@example.jp
                  next if connheader['to'].size > 0
                  connheader['to'] = cv[1]
                  connvalues += 1

                elsif cv = e.match(/\A\s+Subject:\s+(.+)\z/)
                  #  Subject: ...
                  next if connheader['subject'].size > 0
                  connheader['subject'] = cv[1]
                  connvalues += 1

                elsif cv = e.match(%r|\A\s+Sent:\s+([A-Z][a-z]{2},.+[-+]\d{4})\z|) ||
                      cv = e.match(%r|\A\s+Sent:\s+(\d+[/]\d+[/]\d+\s+\d+:\d+:\d+\s.+)|)
                  #  Sent:    Thu, 29 Apr 2010 18:14:35 +0000
                  #  Sent:    4/29/99 9:19:59 AM
                  next if connheader['date'].size > 0
                  connheader['date'] = cv[1]
                  connvalues += 1
                end
              end
            end
          end

          return nil if recipients == 0
          require 'sisimai/string'
          require 'sisimai/smtp/status'

          dscontents.map do |e|
            if mhead['received'].size > 0
              # Get localhost and remote host name from Received header.
              r0 = mhead['received']
              ['lhost', 'rhost'].each { |a| e[a] ||= '' }
              e['lhost'] = Sisimai::RFC5322.received(r0[0]).shift if e['lhost'].empty?
              e['rhost'] = Sisimai::RFC5322.received(r0[-1]).pop  if e['rhost'].empty?
            end
            e['diagnosis'] = Sisimai::String.sweep(e['diagnosis'])

            if cv = e['diagnosis'].match(/\AMSEXCH:.+\s*[(]([0-9A-F]{8})[)]\s*(.*)\z/)
              #     MSEXCH:IMS:KIJITORA CAT:EXAMPLE:EXCHANGE 0 (000C05A6) Unknown Recipient
              capturedcode = cv[1]
              errormessage = cv[2]
              pseudostatus = ''

              ErrorCodeTable.each_key do |r|
                # Find captured code from the error code table
                next unless ErrorCodeTable[r].index(capturedcode)
                e['reason'] = r
                pseudostatus = Sisimai::SMTP::Status.code(r)
                e['status'] = pseudostatus if pseudostatus.size > 0
                break
              end
              e['diagnosis'] = errormessage
            end

            unless e['reason'] 
              # Could not detect the reason from the value of "diagnosis".
              if e['alterrors']
                # Copy alternative error message
                e['diagnosis'] = e['alterrors'] + ' ' + e['diagnosis']
                e['diagnosis'] = Sisimai::String.sweep(e['diagnosis'])
                e.delete('alterrors')
              end
            end

            e['spec']   = e['reason'] == 'mailererror' ? 'X-UNIX' : 'SMTP'
            e['action'] = 'failed' if e['status'] =~ /\A[45]/
            e['agent']  = Sisimai::MTA::Exchange.smtpagent
            e.delete('msexch')
            e.each_key { |a| e[a] ||= '' }
          end

          if rfc822part.size == 0
            # When original message does not included in the bounce message
            rfc822part += sprintf("From: %s\n", connheader['to'])
            rfc822part += sprintf("Date: %s\n", connheader['date'])
            rfc822part += sprintf("Subject: %s\n", connheader['subject'])
          end
          return { 'ds' => dscontents, 'rfc822' => rfc822part }
        end

      end
    end
  end
end
