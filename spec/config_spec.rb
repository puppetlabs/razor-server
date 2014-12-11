# -*- encoding: utf-8 -*-
require 'spec_helper'
require 'pathname'

describe Razor::Config do
  def make_config(content)
    Dir.mktmpdir do |dir|
      fname = Pathname(dir) + "config.yaml"
      if content
        hash = { 'all' => {} }
        # Break the paths in content into nested hashes
        content.each do |key, value|
          path = key.to_s.split(".")
          last = path.pop
          path.inject(hash['all']) { |v, k| v[k] ||= {}; v[k] if v }[last] = value
        end
        # Write the resulting YAML file
        fname.open('w') { |fh| fh.write hash.to_yaml }
      end
      Razor::Config.new(Razor.env, fname.to_s)
    end
  end

  describe "loading" do
    it "should raise InvalidConfigurationError for nonexistant config" do
      expect { make_config(nil) }.to raise_error(Razor::InvalidConfigurationError)
    end

    it "should tolerate an empty config file" do
      make_config({}).should be_an_instance_of(Razor::Config)
    end
  end

  describe "validating" do
    CONFIG_DEFAULTS = {
      "repo_store_root" => Dir.tmpdir,
      "match_nodes_on" => ["mac"]
    }

    def validate(content)
      key = content.keys.first
      # For the mandatroy keys, fill them in with default values, unless
      # they are set to :none which indicates that the test wants to test a
      # config where that entry is entirely missing
      CONFIG_DEFAULTS.keys.each do |k|
        if content[k] == :none
          content.delete(k)
        elsif not content.key?(k)
          content[k] = CONFIG_DEFAULTS[k]
        end
      end

      make_config(content).validate!
      true
    rescue Razor::InvalidConfigurationError => e
      # The first key in content is the one we are testing; if we get an
      # error about any other key, something strange is happening
      raise e if e.key != key
      false
    end

    describe "facts.blacklist" do
      [ "id", "uptime.*" ].each do |s|
        it "should accept /#{s}/" do
          validate("facts.blacklist" => ["/#{s}/"]).should be_true
        end
      end

      [ "*", "[a-z*" ].each do |s|
        it "should reject /#{s}/" do
          validate("facts.blacklist" => ["/#{s}/"]).should be_false
        end
      end

      [ "*", "[a-z*" ].each do |s|
        it "should accept a literal #{s}" do
          validate("facts.blacklist" => [s]).should be_true
        end
      end
    end

    describe "repo_store_root" do
      it "should require that repo_store_root is set" do
        validate("repo_store_root" => :none).should be_false
      end

      it "should reject a non existing root" do
        Dir.mktmpdir do |dir|
          root = Pathname(dir) + "not_there"
          validate('repo_store_root' => root.to_s).should be_false
        end
      end

      it "should accept an existing directory" do
        Dir.mktmpdir do |dir|
          validate('repo_store_root' => dir).should be_true
        end
      end

      it "should reject a relative path" do
        Dir.mktmpdir do |dir|
          (Pathname(dir) + "sub").mkpath
          Dir.chdir(dir) do
            validate('repo_store_root' => "sub").should be_false
          end
        end
      end
    end

    describe "invert_protect_new_nodes_for_subnets" do
      it "should reject non arrays" do
        validate("invert_protect_new_nodes_for_subnets" => "192.168.1.0/24").should be_false
      end

      it "should reject arrays that have values that are not a CIDR address" do
        data = [
          '192.168.2.0/255.255.255.0', #not a CIDR
        ]
        validate("invert_protect_new_nodes_for_subnets" => data).should be_false
      end

      it "should reject arrays that have values that are not valid IP addresses" do
        data = [
          '192.168.256.0/24', # 256 not valid in an IP address
        ]
        validate("invert_protect_new_nodes_for_subnets" => data).should be_false
      end

      it "should reject arrays that have values with invalid subnet masks" do
        data = [
          '192.168.2.0/33', # 33 not valid mask (max 32)
        ]
        validate("invert_protect_new_nodes_for_subnets" => data).should be_false
      end

      it "should accept arrays with all valid CIDRs" do
        data = [
          '192.168.1.0/24',
          '172.16.0.0/16',
          '10.0.0.0/8',
        ]
        validate("invert_protect_new_nodes_for_subnets" => data).should be_true
      end
    end

    describe "match_nodes_on" do
      it "should require that it is set" do
        validate('match_nodes_on' => :none).should be_false
      end

      it "should require that it is a nonempty array" do
        validate('match_nodes_on' => "xxmac").should be_false
        validate('match_nodes_on' => []).should be_false
      end

      it "should only accept entries from HW_INFO_KEYS" do
        (1..Razor::Config::HW_INFO_KEYS.size-1).each do |i|
          keys = Razor::Config::HW_INFO_KEYS.take(i)
          validate('match_nodes_on' => keys).should be_true
        end
        validate('match_nodes_on' => ['net0', 'net1']).should be_false
      end
    end
  end

  shared_examples "expanding paths" do |setting|
    let :setting_name    do setting + '_path' end
    let :setting_default do File.join(Razor.root, setting + 's') end

    [1, {}, [], {"one" => "two"}, ["one", "two"], ["/bin", "/sbin"]].each do |bad|
      it "should raise if #{setting}_path is bad: #{bad.inspect}" do
        Razor.config[setting_name] = bad
        expect { Razor.config.send(setting_name + 's') }.to raise_error
      end
    end

    it "should default to 'brokers' under the application root" do
      Razor.config.values.delete(setting_name)
      Razor.config.send(setting_name + 's').should == [setting_default]
    end

    it "should split paths on ':'" do
      Razor.config[setting_name] = '/one:/two'
      Razor.config.send(setting_name + 's').should == ['/one', '/two']
    end

    it "should work if only a single path is specified" do
      Razor.config[setting_name] = '/one'
      Razor.config.send(setting_name + 's').should == ['/one']
    end

    it "should make relative paths absolute, from the app root" do
      Razor.config[setting_name] = 'one'
      Razor.config.send(setting_name + 's').should == [File.join(Razor.root, 'one')]
    end

    it "should handle a mix of relative and absolute paths" do
      Razor.config[setting_name] = '/one:two:/three'
      Razor.config.send(setting_name + 's').should == ['/one', File.join(Razor.root, 'two'), '/three']
    end

    it "should handle relative paths" do
      Razor.config[setting_name] = '../one'
      Razor.config.send(setting_name + 's').should == [(Pathname(Razor.root) + '../one').to_s]
    end

    it "should ignore the first path component being empty" do
      Razor.config[setting_name] = ':/two:/three'
      Razor.config.send(setting_name + 's').should == ['/two', '/three']
    end

    it "should ignore a middle path component being empty" do
      Razor.config[setting_name] = '/one::/three'
      Razor.config.send(setting_name + 's').should == ['/one', '/three']
    end

    it "should ignore the final path component being empty" do
      Razor.config[setting_name] = '/one:/two:'
      Razor.config.send(setting_name + 's').should == ['/one', '/two']
    end
  end

  describe "task_paths" do
    it_behaves_like "expanding paths", 'task'
  end

  describe "broker_paths" do
    it_behaves_like "expanding paths", 'broker'
  end
end
