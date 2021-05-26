require 'redis'
require 'concurrent-ruby'

module SAFE
  class Client
    attr_reader :configuration

    @@redis_connection = Concurrent::ThreadLocalVar.new(nil)


    def self.redis_connection(config)
      cached = (@@redis_connection.value ||= { url: config.redis_url, connection: nil})
      return cached[:connection] if !cached[:connection].nil? && config.redis_url == cached[:url]

      Redis.new(url: config.redis_url).tap do |instance|
        RedisClassy.redis = instance
        @@redis_connection.value = { url: config.redis_url, connection: instance }
      end
    end

    def initialize(config = SAFE.configuration)
      @configuration = config
    end

    def configure
      yield configuration
    end

    def create_workflow(name)
      begin
        name.constantize.create
      rescue NameError
        raise WorkflowNotFound.new("Workflow with given name doesn't exist")
      end
      flow
    end

    def start_workflow(workflow, job_names = [])
      workflow.mark_as_started
      persist_workflow(workflow)

      jobs = if job_names.empty?
               workflow.initial_jobs
             else
               job_names.map {|name| workflow.find_job(name) }
             end

      jobs.each do |job|
        enqueue_job(workflow.id, job)
      end
    end

    def stop_workflow(id)
      workflow = find_workflow(id)
      workflow.mark_as_stopped
      persist_workflow(workflow)
    end

    def next_free_job_id(workflow_id, job_klass)
      job_id = nil

      loop do
        job_id = SecureRandom.uuid
        available = !redis.hexists("safe.jobs.#{workflow_id}.#{job_klass}", job_id)

        break if available
      end

      job_id
    end

    def next_free_workflow_id
      id = nil
      loop do
        id = SecureRandom.uuid
        available = !redis.exists("safe.workflow.#{id}")

        break if available
      end

      id
    end

    def all_workflows
      redis.scan_each(match: "safe.workflows.*").map do |key|
        id = key.sub("safe.workflows.", "")
        find_workflow(id)
      end
    end

    def find_not_finished_workflow_by(params)
      all_workflows.detect do |workflow|
        if params[:linked_type]
          linked_record_exists(params) && !workflow.finished? && params.all? { |k, v| workflow.to_hash[k] == v }
        else
          !workflow.finished? && params.all? { |k, v| workflow.to_hash[k] == v }
        end
      end
    end

    def find_workflow(id)
      data = redis.get("safe.workflows.#{id}")

      unless data.nil?
        hash = SAFE::JSON.decode(data, symbolize_keys: true)
        keys = redis.scan_each(match: "safe.jobs.#{id}.*")

        nodes = keys.each_with_object([]) do |key, array|
          array.concat redis.hvals(key).map { |json| SAFE::JSON.decode(json, symbolize_keys: true) }
        end

        workflow_from_hash(hash, nodes)
      else
        raise WorkflowNotFound.new("Workflow with given id doesn't exist")
      end
    end

    def persist_workflow(workflow)
      redis.set("safe.workflows.#{workflow.id}", workflow.to_json)

      workflow.jobs.each {|job| persist_job(workflow.id, job) }
      workflow.mark_as_persisted

      true
    end

    def persist_job(workflow_id, job)
      redis.hset("safe.jobs.#{workflow_id}.#{job.klass}", job.id, job.to_json)
    end

    def find_job(workflow_id, job_name)
      job_name_match = /(?<klass>\w*[^-])-(?<identifier>.*)/.match(job_name)

      data = if job_name_match
               find_job_by_klass_and_id(workflow_id, job_name)
             else
               find_job_by_klass(workflow_id, job_name)
             end

      return nil if data.nil?

      data = SAFE::JSON.decode(data, symbolize_keys: true)
      SAFE::Job.from_hash(data)
    end

    def destroy_workflow(workflow)
      redis.del("safe.workflows.#{workflow.id}")
      workflow.jobs.each {|job| destroy_job(workflow.id, job) }
    end

    def destroy_job(workflow_id, job)
      redis.del("safe.jobs.#{workflow_id}.#{job.klass}")
    end

    def expire_workflow(workflow, ttl=nil)
      ttl = ttl || configuration.ttl
      redis.expire("safe.workflows.#{workflow.id}", ttl)
      workflow.jobs.each {|job| expire_job(workflow.id, job, ttl) }
    end

    def expire_job(workflow_id, job, ttl=nil)
      ttl = ttl || configuration.ttl
      redis.expire("safe.jobs.#{workflow_id}.#{job.klass}", ttl)
    end

    def enqueue_job(workflow_id, job)
      job.enqueue!
      persist_job(workflow_id, job)

      queue = job.queue || configuration.namespace
      delay = Integer(configuration.job_delay).seconds

      SAFE::Worker.set(queue: queue, wait: delay).perform_later(*[workflow_id, job.name])
    end

    private

    def linked_record_exists(params)
      params[:linked_type].constantize.find(params[:linked_id])
    rescue ActiveRecord::RecordNotFound => e
      false
    end

    def find_job_by_klass_and_id(workflow_id, job_name)
      job_klass, job_id = job_name.split('|')

      redis.hget("safe.jobs.#{workflow_id}.#{job_klass}", job_id)
    end

    def find_job_by_klass(workflow_id, job_name)
      new_cursor, result = redis.hscan("safe.jobs.#{workflow_id}.#{job_name}", 0, count: 1)

      return nil if result.empty?

      job_id, job = *result[0]

      job
    end

    def workflow_from_hash(hash, nodes = [])
      flow = hash[:klass].constantize.new(*hash[:arguments])
      flow.jobs = []
      flow.stopped = hash.fetch(:stopped, false)
      flow.id = hash[:id]
      flow.linked_type = hash[:linked_type]
      flow.linked_id = hash[:linked_id]

      if monitor = MonitorClient.load_workflow(flow)
        flow.monitor = monitor
        flow.link(monitor.monitorable)
      end

      flow.jobs = nodes.map do |node|
        SAFE::Job.from_hash(node)
      end

      flow
    end

    def redis
      self.class.redis_connection(configuration)
    end
  end
end
