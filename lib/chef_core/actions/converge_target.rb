#
# Copyright:: Copyright (c) 2017 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "pathname"
require "tempfile"
require "chef-config/path_helper"
require "chef_core/actions/base"

module ChefCore
  module Actions
    class ConvergeTarget < Base

      RUN_REPORTER_PATH = File.join(__dir__, "../../../resources/chef_run_reporter.rb").freeze

      def perform_action
        local_policy_path = config.delete :local_policy_path
        remote_tmp = target_host.temp_dir
        remote_dir_path = target_host.normalize_path(remote_tmp)
        # Ensure the directory is owned by the connecting user,
        # otherwise we won't be able to put things into it over scp as that user.
        remote_policy_path = create_remote_policy(local_policy_path, remote_dir_path)
        remote_config_path = create_remote_config(remote_dir_path)
        create_remote_handler(remote_dir_path)
        upload_trusted_certs(remote_dir_path)

        notify(:running_chef)
        cmd_str = run_chef_cmd(remote_dir_path,
          File.basename(remote_config_path),
          File.basename(remote_policy_path))
        c = target_host.run_command(cmd_str)
        target_host.del_dir(remote_dir_path)
        if c.exit_status == 0
          ChefCore::Log.info(c.stdout)
          notify(:success)
        elsif c.exit_status == 35
          notify(:reboot)
        else
          notify(:converge_error)
          ChefCore::Log.error("Error running command [#{cmd_str}]")
          ChefCore::Log.error("stdout: #{c.stdout}")
          ChefCore::Log.error("stderr: #{c.stderr}")
          handle_ccr_error
        end
      end

      def create_remote_policy(local_policy_path, remote_dir_path)
        remote_policy_path = File.join(remote_dir_path, File.basename(local_policy_path))
        notify(:creating_remote_policy)
        begin
          target_host.upload_file(local_policy_path, remote_policy_path)
        rescue RuntimeError => e
          ChefCore::Log.error(e)
          raise PolicyUploadFailed.new
        end
        remote_policy_path
      end

      def create_remote_config(dir)
        remote_config_path = File.join(dir, "workstation.rb")

        workstation_rb = <<~EOM
          local_mode true
          color false
          cache_path "#{target_host.ws_cache_path}"
          chef_repo_path "#{target_host.ws_cache_path}"
          require_relative "chef_run_reporter"
          reporter = ChefCore::ChefRunReporter.new
          report_handlers << reporter
          exception_handlers << reporter
        EOM

        # add the target host's log level value
        # (we don't set a location because we want output to
        #   go in stdout for reporting back to chef-apply)
        unless config[:target_log_level].nil?
          workstation_rb << <<~EOM
            log_level :#{config[:target_log_level]}
          EOM
        end

        # Maybe add data collector endpoint.
        if !config[:data_collector_url].nil? && !config[:data_collector_token].nil?
          workstation_rb << <<~EOM
            data_collector.server_url "#{config[:data_collector_url]}"
            data_collector.token "#{config[:data_collector_token]}"
            data_collector.mode :solo
            data_collector.organization "Chef Workstation"
          EOM
        end

        begin
          config_file = Tempfile.new
          config_file.write(workstation_rb)
          config_file.close
          target_host.upload_file(config_file.path, remote_config_path)
        rescue RuntimeError
          raise ConfigUploadFailed.new
        ensure
          config_file.unlink
        end
        remote_config_path
      end

      def create_remote_handler(remote_dir)
        remote_handler_path = File.join(remote_dir, "chef_run_reporter.rb")
        target_host.upload_file(RUN_REPORTER_PATH, remote_handler_path)
        remote_handler_path
      rescue RuntimeError
        raise HandlerUploadFailed.new
      end

      def upload_trusted_certs(dir)
        local_tcd = ChefConfig::PathHelper.escape_glob_dir(config[:trusted_certs_dir])
        certs = Dir.glob(File.join(local_tcd, "*.{crt,pem}"))
        return if certs.empty?

        notify(:uploading_trusted_certs)
        remote_tcd = "#{dir}/trusted_certs"
        target_host.make_directory(remote_tcd)
        certs.each do |cert_file|
          target_host.upload_file(cert_file, "#{remote_tcd}/#{File.basename(cert_file)}")
        end
      end

      def chef_report_path
        @chef_report_path ||= target_host.normalize_path(File.join(target_host.ws_cache_path, "cache", "run-report.json"))
      end

      def handle_ccr_error
        require "chef_core/actions/converge_target/ccr_failure_mapper"
        mapper_opts = {}
        content = target_host.fetch_file_contents(chef_report_path)
        if content.nil?
          report = {}
          mapper_opts[:failed_report_path] = chef_report_path
          ChefCore::Log.error("Could not read remote report at #{chef_report_path}")
        else
          # We need to delete the stacktrace after copying it over. Otherwise if we get a
          # remote failure that does not write a chef stacktrace its possible to get an old
          # stale stacktrace.
          target_host.del_file(chef_report_path)
          report = JSON.parse(content)
          ChefCore::Log.error("Remote chef-client error follows:")
          ChefCore::Log.error(report["exception"])
        end

        mapper = ConvergeTarget::CCRFailureMapper.new(report["exception"],
          mapper_opts)
        mapper.raise_mapped_exception!
      end

      # TODO - move into target_host as 'get_ccr_command_string'
      # Chef will try 'downloading' the policy from the internet unless we pass it a valid, local file
      # in the working directory. By pointing it at a local file it will just copy it instead of trying
      # to download it.
      #
      # Chef 13 on Linux requires full path specifiers for --config and --recipe-url while on Chef 13 and 14 on
      # Windows must use relative specifiers to prevent URI from causing an error
      # (https://github.com/chef/chef/pull/7223/files).
      def run_chef_cmd(working_dir, config_file, policy)
        case target_host.base_os
        when :windows
          "Set-Location -Path #{working_dir}; " +
            # We must 'wait' for chef-client to finish before changing directories and Out-Null does that
            "chef-client -z --config #{File.join(working_dir, config_file)} --recipe-url #{File.join(working_dir, policy)} | Out-Null; " +
            # We have to leave working dir so we don't hold a lock on it, which allows us to delete this tempdir later
            "Set-Location C:/; " +
            "exit $LASTEXITCODE"
        else
          # cd is shell a builtin, so we'll invoke bash. This also means all commands are executed
          # with sudo (as long as we are hardcoding our sudo use)
          "bash -c 'cd #{working_dir}; chef-client -z --config #{File.join(working_dir, config_file)} --recipe-url #{File.join(working_dir, policy)}'"
        end
      end

      class ConfigUploadFailed < ChefCore::Error
        def initialize(); super("CHEFUPL003"); end
      end

      class HandlerUploadFailed < ChefCore::Error
        def initialize(); super("CHEFUPL004"); end
      end

      class PolicyUploadFailed < ChefCore::Error
        def initialize(); super("CHEFUPL005"); end
      end
    end
  end
end
