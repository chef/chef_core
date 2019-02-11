#
# Copyright:: Copyright (c) 2018 Chef Software Inc.
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

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "chef_core/cliux/version"

Gem::Specification.new do |spec|
  spec.name          = "chef-core_cliux"
  spec.version       = ChefCore::CLIUX::VERSION
  spec.authors       = ["Chef Software, Inc"]
  spec.email         = ["workstation@chef.io"]

  spec.summary       = "Common CLI UX tools for Chef ruby components"
  spec.description   = "Common CLI UX tools for for Chef ruby components"
  spec.homepage      = "https://github.com/chef/chef_core-cliux"
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 2.5.0"

  spec.files = %w{LICENSE README.md} +
    Dir.glob("Gemfile*") + # Includes Gemfile and locks
    Dir.glob("*.gemspec") +
    Dir.glob("{lib,spec}/**/*", File::FNM_DOTMATCH).reject { |f| File.directory?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "chef_core"

  spec.add_dependency "pastel" # A color library
  spec.add_dependency "tty-spinner" # The tty-* libraries are a nice set of terminal output gems
  spec.add_dependency "tty-color"
  spec.add_dependency "tty-cursor"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "pry-byebug"
  spec.add_development_dependency "pry-stack_explorer"
  spec.add_development_dependency "rspec_junit_formatter"
  spec.add_development_dependency "chefstyle"
end
