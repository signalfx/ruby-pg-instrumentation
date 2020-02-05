require 'pg/instrumentation/version'
require 'opentracing'

module PG
  module Instrumentation
    class << self

      attr_accessor :tracer

      def instrument(tracer: OpenTracing.global_tracer)
        begin
          require 'pg'
        rescue LoadError
          return
        end

        @tracer = tracer

        patch_methods unless @instrumented
        @instrumented = true
      end

      def patch_methods
        ::PG::Connection.class_eval do

          alias_method :initialize_original, :initialize
          alias_method :async_exec_original, :async_exec
          alias_method :exec_original, :exec
          alias_method :exec_params_original, :exec_params
          alias_method :prepare_original, :prepare
          alias_method :exec_prepared_original, :exec_prepared

          def initialize(*args)
            return initialize_original(*args) if args.empty?

            hash_arg = args.first.is_a?( Hash ) ? args.first : {}
            db_name = hash_arg.fetch(:dbname, nil)
            db_user = hash_arg.fetch(:user, nil)
            host = hash_arg.fetch(:host, nil)
            port = hash_arg.fetch(:port, nil)

            @shared_tags = {
              'span.kind' => 'client',
              'component' => 'pg',
              'db.type' => 'pg'}

            @shared_tags['db.instance'] = db_name if db_name
            @shared_tags['db.user'] = db_user if db_user
            @shared_tags['peer.hostname'] = host if host
            @shared_tags['peer.port'] = port if port
            @shared_tags['peer.address'] = "pg://#{host}:#{port}" if host && port

            operation_name = 'pg.initialize'
            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: @shared_tags)

            initialize_original(*args)

          rescue => e
            log_error(scope.span, e) if scope
          ensure
            scope.close if scope
          end

          def async_exec(*args)
            tags = @shared_tags.dup

            sql = args.first.to_s[0, 1024]
            tags['db.statement'] = sql

            default_op_name = 'pg.query'
            operation_name = get_operation_name(sql, default_op_name)

            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: tags)

            async_exec_original(*args)

          rescue => e
            log_error(scope.span, e) if scope
          ensure
            scope.close if scope
          end

          def exec(*args)
            tags = @shared_tags.dup

            sql = args.first.to_s[0, 1024]
            tags['db.statement'] = sql

            default_op_name = 'pg.query'
            operation_name = get_operation_name(sql, default_op_name)
            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: tags)

            exec_original(*args)

          rescue => e
            log_error(scope.span, e) if scope
          ensure
            scope.close if scope
          end

          def exec_params(*args)
            tags = @shared_tags.dup

            sql = args.first.to_s[0, 1024]
            tags['db.statement'] = sql

            default_op_name = 'pg.query'
            operation_name = get_operation_name(sql, default_op_name)

            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: tags)

            exec_params_original(*args)

          rescue => e
            log_error(scope.span, e) if scope
          ensure
            scope.close if scope
          end

          def prepare(*args)
            tags = @shared_tags.dup

            sql = args[1].to_str[0, 1024]
            tags['db.statement'] = sql
            tags['prepared.statement.name'] = args.first

            default_op_name = 'pg.prepare'
            operation_name = get_operation_name(sql, default_op_name)

            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: tags)

            prepare_original(*args)

            rescue => e
              log_error(scope.span, e) if scope
            ensure
              scope.close if scope
            end

          def exec_prepared(*args)
            tags = @shared_tags.dup

            tags['prepared.statement.name'] = args.first
            tags['prepared.statement.input'] = args[1][0, 21]
            operation_name = 'pg.exec_prepared'
            scope = ::PG::Instrumentation.tracer.start_active_span(operation_name, tags: tags)

            exec_prepared_original(*args)

          rescue => e
            log_error(scope.span, e) if scope
          ensure
            scope.close if scope
          end

          # Helper functions
          def get_operation_name(sql, default)
            sql_split = sql.split(' ')
            candidate = sql_split[0].upcase if sql_split.length > 1
            return candidate if !candidate.nil? && !candidate.empty?

            return default
          rescue
          end

          def log_error(span, error)
            span.set_tag('error', true)
            span.log_kv(key: 'message',
                        value: error.message,
                        :error_kind => error.class.to_s,
                        :error_object => error,
                        :error_stack =>  error.backtrace.join("\n"))

            raise error
          end
        end # class_eval
      end
    end
  end
end
