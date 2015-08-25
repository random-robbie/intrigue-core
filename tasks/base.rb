require 'timeout'

module Intrigue
class BaseTask
  include Sidekiq::Worker

  def self.inherited(base)
    TaskFactory.register(base)
  end

  def perform(task_id, entity_id, options, handlers, hook_uri=nil)

    #######################
    # Get the Task Result #
    #######################
    @task_result = Intrigue::Model::TaskResult.find task_id
    @entity = Intrigue::Model::Entity.find entity_id

    ###################
    # Create a Logger #
    ###################
    @task_log = @task_result.log

    # We need a way to skip the actual setup,run,cleanup of the task if
    # the caller gave us broken input. We still want to get a result
    # back to the caller though. Assume it's good, and check input along
    # the way.
    broken_input = false

    #
    # Do a little logging. Do it for the kids.
    #
    @task_log.log "Id: #{task_id}"
    @task_log.log "Entity: #{@entity.type}##{@entity.attributes["name"]}"
    @task_log.log "Options: #{options}"

    ###################
    # Sanity Checking #
    ###################

    # XXX - should we sanity check hook_uri here? probably.
    allowed_types = self.metadata[:allowed_types]

    unless @entity
      @task_log.error "ERROR! No entity!!!"
      broken_input = true
    end

    # Check to make sure this task can receive an entity of this type
    unless allowed_types.include?(@entity.type) || allowed_types.include?("*")
      #raise "ERROR! Can't call #{self.metadata[:name]} on entity: #{entity}"
      @task_log.error "Unable to call #{self.metadata[:name]} on entity: #{@entity}"
      broken_input = true
    end

    ###########################
    # Setup the task result   #
    ###########################
    @task_result.task_name = metadata[:name]
    @task_result.entity = @entity
    @task_result.timestamp_start = Time.now.getutc
    @task_result.id = task_id

    ###################################
    # Perform the setup->run->cleanup #
    ###################################
    unless broken_input
      # Setup creates the following objects:
      # @user_options - a hash of task options
      # @task_result - the final result to be passed back to the caller
      @task_log.log "Calling Setup"
      if setup(task_id, @entity, options)
        # Call run(), which will use _create_entity
        begin
          Timeout.timeout($intrigue_global_timeout) do # 15 minutes should be enough time to hit a class b for a single port w/ masscan
            @task_log.log "Calling Run"

            # Save the task locally
            @task_result.save

            # run the task, which will update @task_log and @task_result
            run

            # Clean up the resulting entities
            @task_result.entities.map{|x| x.to_json }.uniq!

            @task_log.good "Ship it!"
          end
        rescue Timeout::Error
          @task_log.error "ERROR! Timed out"
        end
      else
        @task_log.error "Setup failed, bailing out!"
      end
    end

    #
    # Mark it complete and save it
    #
    # http://stackoverflow.com/questions/178704/are-unix-timestamps-the-best-way-to-store-timestamps
    @task_result.timestamp_end = Time.now.getutc
    @task_result.complete = true
    @task_result.save # Always save to redis

    #
    # Handlers! (other than redis)
    #
    # This is currently used from the core-cli load command - both csv and
    # json handlers are passed, and thus generated by the appropriate lclasses
    # (see lib/report/handlers)
    #
    handlers.each do |handler_type|
      @task_log.log "Processing #{handler_type} handler!"
      options = {:hook_uri => hook_uri} if handler_type == "webhook"
      handler = HandlerFactory.create_by_type(handler_type)
      handler.process(@task_result, options)
    end

    # Run Cleanup
    @task_log.log "Calling cleanup!"
    cleanup unless broken_input

  end

  #########################################################
  # These methods are used to perform work in several steps.
  # they should be overridden by individual tasks, but note that
  # individual tasks must always call super()
  #
  def setup(task_id, entity, user_options)

    # We need to parse options and make sure we're
    # allowed to accept these options. Compare to allowed_options.

    ###
    ### XXX SECURITY - needs gating on options (use the regex values)
    ###

    ###
    ### XXX move all option processing up here, so it happens in one place
    ###     vs having it scattered around throughout the module (_get_option)
    ###

    #
    # allowed options is formatted:
    #    [{:name => "count", :type => "Integer", :default => 1 }, ... ]
    #
    # user_options is formatted:
    #    [{"name" => "option name", "value" => "value"}, ...]
    allowed_options = self.metadata[:allowed_options]

    @user_options = []

    if user_options

      @task_log.log "Got user options list: #{user_options}"

      # for each of the user-supplied options
      user_options.each do |user_option| # should be an array of hashes

        #@task_log.log "Processing user option: #{user_option}"

        # go through the allowed options
        allowed_options.each do |allowed_option|

          #@task_log.log "Checking against allowed option list: #{allowed_option}"

          # if we have a match
          if "#{user_option["name"]}" == "#{allowed_option[:name]}"

            #@task_log.log "Verifying this user option: #{user_option["name"]}"

            ###
            ### Match the user option against it's specified regex
            ###

            #@task_log.log "Allowed option: #{allowed_option}"

            # XXX - we need to regex the option in order to accept it
            if allowed_option[:regex] == "integer"
              @task_log.log "Regex should match an integer"
              regex = /^\d+$/
            elsif allowed_option[:regex] == "boolean"
              @task_log.log "Regex should match a boolean"
              regex = /(true|false)/
            elsif allowed_option[:regex] == "alpha_numeric"
              @task_log.log "Regex should match an alpha-numeric string"
              regex = /^[a-zA-Z0-9\_\;\(\)\,\?\.\-\_\/\~\=\ \,\?]*$/
            elsif allowed_option[:regex] == "alpha_numeric_list"
              @task_log.log "Regex should match an alpha-numeric list"
              regex = /^[a-zA-Z0-9_;\\(),\?\.\-\_]*$/
            elsif allowed_option[:regex] == "filename"
              @task_log.log "Regex should match a filename"
              regex = /(?:\..*(?!\/))+/
            elsif allowed_option[:regex] == "ip_address"
              @task_log.log "Regex should match an IP Address"
              regex = /^(\s*((([0-9A-Fa-f]{1,4}:){7}([0-9A-Fa-f]{1,4}|:))|(([0-9A-Fa-f]{1,4}:){6}(:[0-9A-Fa-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){5}(((:[0-9A-Fa-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9A-Fa-f]{1,4}:){4}(((:[0-9A-Fa-f]{1,4}){1,3})|((:[0-9A-Fa-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){3}(((:[0-9A-Fa-f]{1,4}){1,4})|((:[0-9A-Fa-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){2}(((:[0-9A-Fa-f]{1,4}){1,5})|((:[0-9A-Fa-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9A-Fa-f]{1,4}:){1}(((:[0-9A-Fa-f]{1,4}){1,6})|((:[0-9A-Fa-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9A-Fa-f]{1,4}){1,7})|((:[0-9A-Fa-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))(%.+)?\s*)|((\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}))$/
            else
              @task_log.error "Unspecified regex for this option #{allowed_option[:name]}"
              @task_log.error "FATAL! Unable to continue!"
              return nil
            end

            # Run the regex
            unless regex.match "#{user_option["value"]}"
              @task_log.error "Regex didn't match"
              @task_log.error "Option #{user_option["name"]} does not match regex: #{regex.to_s} (#{user_option["value"]})!"
              @task_log.error "FATAL! No task processing since regex didn't match option!"
              return nil
            end

            ###
            ### End Regex matching
            ###

            # We have an allowed option, with the right kind of value
            # ...Now set the correct type

            # So basically, things like core-cli are parsing data as strings, and are sending us
            # all of our options as strings. Which sucks. We have to do the explicit conversion
            # to the right type if we want things to go smoothly. I'm sure there's a better
            # way to do this in ruby, but i equally sure don't know what it is. We'll raise
            # a FATAL if there's something we can't handle

            if allowed_option[:type] == "Integer"
              # convert to integer
              #@task_log.log "Converting #{user_option["name"]} to an integer"
              user_option["value"] = user_option["value"].to_i
            elsif allowed_option[:type] == "String"
              # do nothing, we can just pass strings through
              #@task_log.log "No need to convert #{user_option["name"]} to a string"
              user_option["value"] = user_option["value"]
            elsif allowed_option[:type] == "Boolean"
              # use our monkeypatched .to_bool method (see initializers)
              #@task_log.log "Converting #{user_option["name"]} to a bool"
              user_option["value"] = user_option["value"].to_bool
            else
              # throw an error, we likely have a string we don't know how to cast
              @task_log.error "FATAL! Don't know how to handle this option when it's given to us as a string."
              return nil
            end

            # hurray, we can accept this value
            #@task_log.good "Congrats! Allowed this user option: #{user_option}"
            @user_options << { allowed_option[:name] => user_option["value"] }
          end
        end

      end
      @task_log.log "Task configured with the following options: #{@user_options}"
    else
      @task_log.log "No User options"
    end

    @task_result.save

  true
  end

  # This method is overridden
  def run
  end

  def cleanup()
    @task_log = nil
    @user_options = nil
    @task_result = nil
  end
  #
  #########################################################

  # Override this method if the task has external dependencies
  def check_external_dependencies
    true
  end

  private

    # Convenience Method to execute a system command semi-safely
    #  !!!! Don't send anything to this without first whitelisting user input!!!
    def _unsafe_system(command)

      ###                  ###
      ###  XXX - SECURITY  ###
      ###                  ###

      if command =~ /(\||\;|\`)/
        #raise "Illegal character"
        @task_log.error "FATAL Illegal character in #{command}"
        return
      end

      `#{command}`
    end

    #
    # This is a helper method, use this to create entities from within tasks
    #
    def _create_entity(type, attributes)
      @task_log.good "Creating entity: #{type}, #{attributes.inspect}"

      # Create the entity, validating the attributes
      entity = EntityFactory.create_by_type(type,attributes)

      # If we don't get anything back, safe to assume we can't move on
      unless entity
        @task_log.error "SKIPPING Unable to verify & save entity: #{type} #{attributes}"
        return
      end

      # Add to our result set for this task
      @task_result.add_entity entity

    # return the entity
    entity
    end

    def _canonical_name
      "#{self.metadata[:name]}: #{self.metadata[:version]}"
    end

    def _get_entity_attribute(name)
      "#{@task_result.entity.attributes["name"]}"
    end

    def _get_global_config(key)
      begin
        $intrigue_config[key]["value"]
      rescue NoMethodError => e
        puts "Error, invalid config key requested (#{key}) #{e}"
      end
    end

    ###
    ### XXX TODO - move this up into the setup method and make it happen automatically
    ###
    def _get_option(name)

      # Start with nothing
      value = nil

      # First, get the default value by cycling through the allowed options
      method = metadata[:allowed_options].each do |allowed_option|
        value = allowed_option[:default] if allowed_option[:name] == name
      end

      # Then, cycle through the user-provided options
      @user_options.each do |user_option|
        value = user_option[name] if user_option[name]
      end

      #@task_log.log "Option configured: #{name}"

    value
    end

end
end
