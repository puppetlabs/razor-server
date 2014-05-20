# -*- encoding: utf-8 -*-
module Razor::Data
  class DuplicateNodeError < RuntimeError
    attr_reader :hw_info, :nodes

    def initialize(hw_info, nodes)
      @hw_info = hw_info
      @nodes = nodes
    end

    def message
      # TRANSLATORS: the name of the node, and the hardware ID of it.
      template = _("(name=%{name}, id=%{id})")
      message  = node_ids.map { |h| template % {name: h[:name], id: h[:id]} }.join(", ")
      _("Multiple nodes match hw_info %{hw_info}. Nodes: %{nodes}") % {hw_info: hw_info, nodes: message}
    end

    def log_to_nodes!
      log_entry = {
        :event => :boot, :severity => :error,
        :error => :duplicate_node,
        :nodes => node_ids,
        :hw_info => hw_info
      }
      nodes.each { |node| node.log_append(log_entry) }
    end

    def node_ids
      nodes.map { |node| { :name => node.name, :id => node.id } }
    end
  end

  class Node < Sequel::Model
    # Since we generate the name in the database using a trigger, the
    # auto-validation plugin sets up the wrong constraint checks.
    # This updates it to fix that, by moving from "must be present" to
    # "validate not null if explicitly supplied", which allows the database to
    # assign the default if it is not present.
    auto_validate_not_null_columns.delete(:name)
    auto_validate_explicit_not_null_columns << :name

    #See the method schema_type_class() for some special considerations
    #regarding the use of serialization.
    plugin :serialization, :json, :facts
    plugin :serialization, :json, :metadata

    plugin :typecast_on_load, :hw_info

    many_to_one :policy
    one_to_many :node_log_entries

    # The tags that were applied to this node the last time it did a
    # checkin with the microkernel. These are not necessarily the same tags
    # that would apply if the node was matched right now
    many_to_many :tags

    def around_save
      #Re-eval the nodes tags if the metadata has changed.  We dont need
      #this for new nodes or fact changes as they only occur/change on checkin
      #which already triggers tag evaluation.
      need_eval_tags = changed_columns.include?(:metadata)
      super
      publish('eval_tags') if need_eval_tags
    end

    def before_create
      # Support users configuring that we mark all newly discovered nodes as
      # "installed" already, despite having no policy.
      if Razor.config['protect_new_nodes']
        self.installed    = true
        self.installed_at = Time.now
      end
      super
    end

    # Set the hardware info from a hash.
    def hw_hash=(hw_hash)
      self.hw_info = self.class.canonicalize_hw_info(hw_hash)
    end

    # Turn the hw_info back into a hash. Possible keys are the ones in
    # +HW_INFO_KEYS+; all values are strings, except for +mac+, which is an
    # array of strings if any MAC addresses are present
    def hw_hash
      hw_info.inject({}) do |h, p|
        pair = p.split("=", 2)
        if pair[0] == 'mac'
          h['mac'] ||= []
          h['mac'] << pair[1]
        else
          h[pair[0]] = pair[1]
        end
        h
      end
    end

    def task
      if policy
        policy.task
      elsif installed
        Razor::Task.noop_task
      else
        Razor::Task.mk_task
      end
    end

    def domainname
      return nil if hostname.nil?
      hostname.split(".").drop(1).join(".")
    end

    def shortname
      return nil if hostname.nil?
      hostname.split(".").first
    end

    # Retrive the entire log for this node as an array of hashes, ordered
    # by increasing timestamp. In addition to the keys mentioned for
    # +log_append+ each entry will also contain the +timstamp+ in ISO8601
    # format
    def log
      node_log_entries_dataset.order(:timestamp).map do |log|
        { 'timestamp' => log.timestamp.xmlschema }.update(log.entry)
      end
    end

    def freeze
      # Validation, which should not change the object, sometimes does. So
      # validate before we freeze
      validate
      super
    end

    # Log a message to the node's log and save the log. Messages should be
    # hashes, where some of the keys have standard meanings. These keys are
    #
    # +:severity+ - 'info', 'warn' or 'error'
    # +:msg+      - human readable text
    # +:error+    - the kind of error that happened
    # +:action+   - an action the node was told to perform
    # +:event+    - an event on the server, e.g. 'boot'
    #
    # @todo lutter 2013-09-06: narrow down and document what actions and
    # events can be logged, together with the additional information for
    # each
    def log_append(entry, timestamp=nil)
      entry[:severity] ||= 'info'
      # Roundtrip the hash through JSON to make sure we always have the
      # same entries in the log that we would get from loading from DB
      # (otherwise we could have symbols, which will turn into strings on
      # reloading)
      entry = JSON::parse(entry.to_json)
      TorqueBox::Logger.new.info("#{name}: #{entry.inspect}")

      if timestamp
        add_node_log_entry(:timestamp => timestamp, :entry => entry)
      else
        add_node_log_entry(:entry => entry)
      end
    end

    def is_new
      @is_new = true
      self
    end

    def is_new?
      @is_new ? true : false
    end

    #Return an array containing fact regexes that can be used to match nodes
    #These facts will be added to the hw_info
    def self.match_nodes_on_facts
      if Razor.config['match_nodes_on_facts']
        if Razor.config['match_nodes_on_facts'].is_a?(Array)
          criteria = Razor.config['match_nodes_on_facts']
        else
          criteria = [ Razor.config['match_nodes_on_facts'] ]
        end
      else
        criteria = []
      end

      criteria.collect do |c|
        c.sub!('^\^','')
        c.sub!('\$$','')
        "^#{c}$"
      end
    end

    def installed=(value)
      # @todo danielp 2014-04-15: Unfortunately, we can't store false into the
      # database without also storing a time, but time should be nil if we are
      # not installed.  Should fix that, one day, I suspect.
      super(value ? value : nil)
      self.installed_at = if value then DateTime.now else nil end
      return value
    end

    def bind(policy)
      self.policy = policy
      self.boot_count = 1
      # @todo lutter 2013-12-31: we mark the node uninstalled as soon as a
      # policy is bound to it. There's two improvements that could be made:
      # 1. not every policy will be destructive, and we should preserve the
      #    'installed' state for non-destructive policies (requires additional
      #    metadata in tasks)
      # 2. there's a small time window between binding the node and the
      #    task booting in which the node technically is still installed.
      #    We could reset the installed fields only when we boot into the new
      #    policy for the first time, but it seems like a minor win, and would
      #    require a flag to remember whether we've already booted into a
      #    policy or not
      self.installed = nil
      self.root_password = policy.root_password
      self.hostname = policy.hostname_pattern.gsub(/\$\{\s*id\s*\}/, id.to_s)

      if policy.node_metadata
        modify_metadata('no_replace' => true, 'update' => policy.node_metadata)
      end

      self
    end

    # This is a hack around the fact that the auto_validates plugin does
    # not play nice with the JSON serialization plugin (the serializaton
    # happens in the before_save hook, which runs after validation)
    #
    # To avoid spurious error messages, we tell the validation machinery to
    # expect a Hash resp.
    #
    # Add the fields to be serialized to the 'serialized_fields' array
    #
    # FIXME: Figure out a way to address this issue upstream
    def schema_type_class(k)
      if [ :facts, :metadata ].include?(k)
        Hash
      else
        super
      end
    end

    def validate
      super

      unless hw_info.nil?
        # PGArray is not an Array, just behaves like one
        hw_info.is_a?(Sequel::Postgres::PGArray) or hw_info.is_a?(Array) or
          errors.add(:hw_info, _("must be an array"))
        hw_info.each do |p|
          pair = p.split("=", 2)
          pair.size == 2 or
            errors.add(:hw_info, _("entry '%{raw}' is not in the format 'key=value'") % {raw: p})
          (pair[1].nil? or pair[1] == "") and
            errors.add(:hw_info, _("entry '%{raw}' does not have a value") % {raw: p})
          (Razor::Config::HW_INFO_KEYS.include?(pair[0]) or pair[0] =~ /^fact_/) or
            errors.add(:hw_info, _("entry '%{raw}' uses an unknown key %{key}") % {raw: p, key: pair[0]})
          # @todo lutter 2013-09-03: we should do more checking, e.g. that
          # MAC addresses are sane
        end
      end

      if ipmi_hostname.nil?
        ipmi_username and errors.add(:ipmi_username, _('you must also set an IPMI hostname'))
        ipmi_password and errors.add(:ipmi_password, _('you must also set an IPMI hostname'))
      end
    end

    def eval_tags
      new_tags = Tag.match(self)
      (self.tags - new_tags).each { |t| self.remove_tag(t) }
      (new_tags - self.tags).each { |t| self.add_tag(t) }
    end

    # Update the tags for this node and try to bind a policy.
    def match_and_bind
      eval_tags
      Policy.bind(self)
    rescue Razor::Matcher::RuleEvaluationError => e
      log_append :severity => "error", :msg => e.message
      save
      raise e
    end

    # Modify metadata the API reciever does alot of sanity checking.
    # Lets not do to much here and assume that internal use is done with
    # intent.
    def modify_metadata(data)
      new_metadata = metadata

      if data['update']
        data['update'].is_a? Hash or raise ArgumentError, _('update must be a hash')
        replace = (not [true, 'true'].include?(data['no_replace']))
        data['update'].each do |k,v|
          new_metadata[k] = v if replace or not new_metadata[k]
        end
      end
      if data['remove']
        data['remove'].is_a? Array or raise ArgumentError, _('remove must be an array')
        data['remove'].each do |k,v|
          new_metadata.delete(k)
        end
      end
      if data['clear'] == true or data['clear'] == 'true'
        new_metadata = Hash.new
      end

      self.metadata = new_metadata
      save_changes
      self
    end

    # Process a checkin for this node; +body+ must be a hash where
    # +body['facts']+ contains the latest facts from the node. Update the
    # facts in the DB if they have changed since the last checkin. If the
    # node doesn't have a policy applied to it yet, try to match it and
    # return a hash whose +:action+ key contains the next action for the
    # node (+:none+ or +:reboot+)
    def checkin(body)
      new_facts = body['facts'].reject do |k, _|
        Razor.config.fact_blacklisted?(k)
      end
      if facts != new_facts
        self.facts = new_facts
      end

      #Update the hw_info with what facts should be in it
      hw_info_hash = hw_hash.delete_if do |k,v|
        k =~ /^fact_/
      end

      body['facts'].each do |f,v|
        self.class.match_nodes_on_facts.each do |r|
          if f =~ %r[#{r}]
            hw_info_hash['facts'] ||= {}
            hw_info_hash['facts'][f] = v
          end
        end
      end

      hw_info_hash = self.class.canonicalize_hw_info(hw_info_hash)
      if hw_info != hw_info_hash
        self.hw_info = hw_info_hash
      end

      # @todo lutter 2013-09-09: we'd really like to use the DB's idea of
      # time, i.e. have the update statement do 'last_checkin = now()' but
      # that is currently not possible with Sequel
      self.last_checkin = Time.now
      action = :none
      match_and_bind unless policy
      if policy
        log_append(:action => :reboot, :policy => policy.name)
        action = :reboot
      end
      save_changes
      { :action => action }
    end

    # Normalize the hardware info. Be very careful when you change this
    # as this might require a DB migration so that existing nodes can
    # still be found after the change
    #
    # Besides the keys coming in from the MK, +hw_info+ might also be a
    # +hw_hash+, implying that +mac+ might be an array of MAC addresses
    def self.canonicalize_hw_info(hw_info)
      facts = []
      if hw_info["facts"]
        hw_info.delete("facts").each{|k,v| facts.push( ["fact_#{k}",v] ) }
      end

      if macs = hw_info["mac"]
        macs = [ macs ] unless macs.is_a? Array
        macs = macs.map { |mac| mac.gsub(":", "-") }
        # hw_info might contain an array of mac's; spread that out
        hw_info = hw_info.to_a.reject! {|k,v| k == "mac" } +
                  ["mac"].product(macs)
      end

      (hw_info.to_a + facts).map do |k,v|
        # We treat the netXXX keys special so that our hw_info is
        # independent of the order in which the BIOS enumerates NICs. We
        # also don't care about case
        k = "mac" if k =~ /net[0-9]+/
        [k.downcase, v.strip.downcase]
      end.select do |k, v|
        Razor::Config::HW_INFO_KEYS.include?(k) && v && v != "" or
          k =~ /^fact_/
      end.sort do |a, b|
        # Sort the [key, value] pairs lexicographically
        a[0] == b[0] ? a[1] <=> b[1] : a[0] <=> b[0]
      end.map { |pair| "#{pair[0]}=#{pair[1]}" }
    end

    # Look up a node by its hw_info; any node whose hw_info overlaps with
    # the given hw_info is considered to match. If there is more than one
    # matching node, throw a +DuplicateNodeError+. If there is none, create
    # a new node
    def self.lookup(data)
      data['facts'] or data['hw_info'] or
        raise ArgumentError, "Must supply a hash with keys 'facts' or 'hw_info'"

      # If we have facts, the attempt to ID during boot failed.
      if facts = data['facts']
        hw_info_facts = {}
        match_nodes_on_facts.each do |regex|
          facts.keys.each do |fact|
            if fact =~ %r[#{regex}]
              hw_info_facts[fact] = facts[fact]
            end
          end
        end

        # Set up what this nodes hw_info and dhcp mac fields should look like
        hw_info = canonicalize_hw_info({
          'mac'   => facts['macaddress'],
          'uuid'  => facts['uuid'],
          'facts' => hw_info_facts,
        })
        dhcp_mac = facts['macaddress'].gsub(':','-').strip.downcase
      else
        params = data['hw_info']
        dhcp_mac = params.delete("dhcp_mac")
        dhcp_mac = nil if !dhcp_mac.nil? and dhcp_mac.empty?

        hw_info = canonicalize_hw_info(params)
      end

      # For matching nodes, we only consider the +hw_info+ values named in
      # the 'match_nodes_on' config setting or facts that match the match_nodes_on_facts config setting
      hw_match = hw_info.select do |p|
        Razor.config['match_nodes_on'].include?(p.split("=")[0]) or p.split("=")[0] =~ /^fact_/
      end
      hw_match.empty? and raise ArgumentError, _("Lookup was given %{keys}, none of which are configured as match criteria in match_nodes_on (%{match_nodes_on})") % {keys: params.keys, match_nodes_on: Razor.config['match_nodes_on']}
      nodes = self.where(:hw_info.pg_array.overlaps(hw_match)).all

      if nodes.nil? or nodes.size == 0
        node = self.create(:hw_info => hw_info, :dhcp_mac => dhcp_mac)
        node.is_new
      elsif nodes.size == 1
        node = nodes.first

        #Update the dhcp mac if required
        unless dhcp_mac.nil? || node.dhcp_mac == dhcp_mac
          node.dhcp_mac = dhcp_mac
          node.save
        end

        #Update the hw_info.
        if hw_info.reject{|h| h =~ /^fact_/} != node.hw_info.reject{|h| h =~ /^fact_/}
          if hw_info.select{|h| h =~ /^fact_/}
            #We were given facts so update the facts
            node.hw_info = hw_info
          else
            #otherwise preserve the exising facts
            facts = node.hw_info.select{|h| h =~ /^fact_/}
            node.hw_info = hw_info + facts
          end
          node.save
        end

        node
      elsif nodes.size == 2
        #This will happen if a machine could not be ID'ed during boot and has now
        #been identified using facts during the checkin.  One will have facts in its
        #hw_info and the other will not. The real one will be the one with facts.
        #Update the hw_info of the real one and merge the log from the fake one to the
        #new one.
        real_node = nil
        fake_node = nil

        nodes.each do |node|
          if node.hw_info.select{ |h| h =~ /fact_/ }.length > 0
            real_node = node
          else
            fake_node = node
          end
        end

        unless real_node && fake_node
          #Neither have facts this is duplicate error
          raise DuplicateNodeError.new(hw_info, nodes)
        end

        #update the hw_info of the real_node
        real_node.hw_info = hw_info

        fake_node.node_log_entries_dataset.each do |log|
          real_node.log_append(log.entry, log.timestamp)
        end

        fake_node.destroy
        real_node.save
      else
        # We have more than one node matching hw_info; fail
        raise DuplicateNodeError.new(hw_info, nodes)
      end
    end

    def self.stage_done(node_id, name = "")
      node = self[node_id]
      name = node.boot_count if name.nil? or name.empty?
      node.log_append(:event => :stage_done, :stage => name || node.boot_count)
      node.boot_count += 1
      if name == "finished" and node.policy
        node.installed = node.policy.name
      end
      node.save
    end

    def self.search(params)
      nodes = self.dataset
      # Search by hostname
      if params['hostname']
        rx = params.delete("hostname")
        begin
          rx = Regexp.new(rx)
        rescue
          # If we can't compile the user's input into a regexp,
          # just search for the raw string
        end
        nodes = nodes.grep([:hostname, :ipmi_hostname], rx,
                           :case_insensitive => true)
      end
      # Search by hw_info
      hw_info = canonicalize_hw_info(params)
      unless hw_info.empty?
        nodes = nodes.where(:hw_info.pg_array.overlaps(hw_info))
      end
      nodes
    end

    ########################################################################
    # IPMI and power management support code
    def last_known_power_state=(what)
      self.last_power_state_update_at = Time.now()
      super(what)
    end

    # Poll for the IPMI power state of this node, and update the last
    # known state.  This is a synchronous function, and is expected to be
    # called from a background processing queue.
    #
    # We update our power state regardless of the outcome, including setting
    # it to "unknown" on failures of the IPMI code, though not on failures
    # like command execution blowing up.
    #
    # If we have a current power state, and a desired power state, and they
    # don't match, we also queue work to toggle power into the
    # appropriate state.
    def update_power_state!
      begin
        self.last_known_power_state = Razor::IPMI.on?(self) ? 'on' : 'off'

        # If we have both a desired and known power state...
        unless self.desired_power_state.nil? or self.last_known_power_state.nil?
          # ...and they don't match...
          unless self.desired_power_state == self.last_known_power_state
            # ...toggle our power state to what is desired.  This is put into
            # the background because it isn't actually related to our current
            # transaction, and that ensures we do the right thing later.
            self.publish(self.desired_power_state)
          end
        end
      rescue Razor::IPMI::IPMIError
        self.last_known_power_state = nil
        raise
      ensure
        self.save_changes
      end
    end

    # Request a reboot from the machine via IPMI.  This is synchronous, and is
    # expected to be called in the background from the message queue.
    def reboot!
      Razor::IPMI.reset(self)
    end

    # Turn the node on.
    def on
      Razor::IPMI.power(self, true)
    end

    # Turn the node off.
    def off
      Razor::IPMI.power(self, false)
    end
  end
end
