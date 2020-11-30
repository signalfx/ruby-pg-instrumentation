require 'spec_helper'

RSpec.describe PG::Instrumentation do
  describe 'Class Methods' do
    it { should respond_to :instrument }
    it { should respond_to :patch_methods }
  end

  let (:tracer) { OpenTracingTestTracer.build }

  let (:host) { 'localhost' }
  let (:dbname) { 'postgres' }
  let (:user) { 'test_user' }
  let (:port) { 5432 }

  let (:conn) { PG::Connection.connect(dbname: dbname, user: user, host: host, port: port)}

  before do
    PG::Instrumentation.instrument(tracer: tracer)

    ## prevent actual connections
    allow_any_instance_of(PG::Connection).to receive(:new)

    # mock query_original, since we don't care about the results
    allow_any_instance_of(PG::Connection).to receive(:initialize_original).and_return(PG::Connection.new)
    allow_any_instance_of(PG::Connection).to receive(:async_exec_original).and_return(PG::Result.new)
    allow_any_instance_of(PG::Connection).to receive(:exec_original).and_return(PG::Result.new)
    allow_any_instance_of(PG::Connection).to receive(:exec_params_original).and_return(PG::Result.new)
    allow_any_instance_of(PG::Connection).to receive(:prepare_original).and_return(PG::Result.new)
    allow_any_instance_of(PG::Connection).to receive(:exec_prepared_original).and_return(PG::Result.new)
  end

  describe 'fresh start' do
    it 'cleans up' do
      conn.exec 'drop table if exists test_pg '
      conn.exec 'create table test_pg (col1 text, col2 text, col3 text)'

      EXPECTED_TAGS = {
        'component' => 'pg',
        'db.instance' => dbname,
        'db.type' => 'pg',
        'db.user' => user,
        'peer.hostname' => host,
        'peer.port' => port,
        'peer.address' => "pg://#{host}:#{port}",
        'span.kind' => 'client'
      }.freeze

    end
  end

  describe :instrument do
    it "patches the class's async_exec method" do
      expect(conn).to respond_to(:async_exec)
      expect(conn).to respond_to(:async_exec_original)
    end

    it "patches the class's exec method" do
      expect(conn).to respond_to(:exec)
      expect(conn).to respond_to(:exec_original)
    end

    it "patches the class's exec_params method" do
      expect(conn).to respond_to(:exec_params)
      expect(conn).to respond_to(:exec_params_original)
    end

    it "patches the class's prepare method" do
      expect(conn).to respond_to(:prepare)
      expect(conn).to respond_to(:prepare_original)
    end

    it "patches the class's exec_prepared method" do
      expect(conn).to respond_to(:exec_prepared)
      expect(conn).to respond_to(:exec_prepared_original)
    end
  end

  describe 'successfully traces query using `async_exec` method' do
    it 'calls async_exec_original when calling query' do
      expect(conn).to receive(:async_exec_original)
      conn.async_exec('SELECT * FROM test_pg')
    end

    it 'adds a span for async_exec query with tags' do
      statement = 'SELECT * FROM test_pg '
      conn.async_exec(statement)

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['db.statement'] = statement[0..1023]

      expect(tracer.spans.count).to eq 2
      expect(tracer.spans.last.operation_name).to eq 'SELECT'
      expect(tracer.spans.last.tags).to eq expected_tags
    end
  end

  describe 'successfully traces query using `exec` method' do
    it 'calls exec_original when calling query' do
      expect(conn).to receive(:exec_original)
      conn.exec('SELECT * FROM test_pg')
    end

    it 'adds a span for exec query with tags' do
      statement = 'SELECT * FROM test_pg '
      conn.exec(statement)

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['db.statement'] = statement[0..1023]

      expect(tracer.spans.count).to eq 2
      expect(tracer.spans.last.operation_name).to eq 'SELECT'
      expect(tracer.spans.last.tags).to eq expected_tags
    end
  end

  describe 'successfully traces query using `exec_params` method' do
    it 'calls exec_params_original when calling query' do
      expect(conn).to receive(:exec_params_original)
      conn.exec_params('SELECT * FROM test_pg')
    end

    it 'adds a span for exec_params query with tags' do
      statement = 'SELECT * FROM test_pg '
      conn.exec_params(statement, [])

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['db.statement'] = statement[0..1023]

      expect(tracer.spans.count).to eq 2
      expect(tracer.spans.last.operation_name).to eq 'SELECT'
      expect(tracer.spans.last.tags).to eq expected_tags
    end
  end

  describe 'successfully traces query using `prepare` method' do
    it 'calls prepare_original when preparing statement' do
      expect(conn).to receive(:prepare_original)

      conn.prepare('statement1', 'insert into test_pg (col1 , col2, col3) values ($1, $2, $3)')
    end

    it 'adds a span for prepare query with tags' do
      conn.prepare('statement1', 'insert into test_pg (col1 , col2, col3) values ($1, $2, $3)')

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['db.statement'] = 'insert into test_pg (col1 , col2, col3) values ($1, $2, $3)'
      expected_tags['prepared.statement.name'] = 'statement1'

      expect(tracer.spans.count).to eq 2
      expect(tracer.spans.last.operation_name).to eq 'INSERT'
      expect(tracer.spans.last.tags).to eq expected_tags
    end
  end

  describe 'successful traces query using `exec_prepared` method' do
    it 'calls exec_prepared_original when calling prepared statement' do
      expect(conn).to receive(:exec_prepared_original)
      conn.prepare('statement1', 'insert into test_pg (col1 , col2, col3) values ($1, $2, $3)')
      conn.exec_prepared('statement1', ['1', 'Test User', 'User testing...'])
    end

    it 'adds a span for exec_prepared query with tags' do
      conn.prepare('statement1', 'insert into test_pg (col1 , col2, col3) values ($1, $2, $3)')
      conn.exec_prepared('statement1', ['1', 'Test User', 'User testing...'])

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['prepared.statement.name'] = 'statement1'
      expected_tags["prepared.statement.input"] = ["1", "Test User", "User testing..."]

      expect(tracer.spans.count).to eq 3
      expect(tracer.spans.last.operation_name).to eq 'pg.exec_prepared'
      expect(tracer.spans.last.tags).to eq expected_tags
    end
  end

  describe 'failed query' do
    before do
      allow(conn).to receive(:exec_original).and_raise('error')
    end

    it 'sets the error tag and log' do
      statement = 1234
      error = nil
      begin
        conn.exec(statement)
      rescue => e
        error = e
      end

      expected_tags = EXPECTED_TAGS.dup
      expected_tags['db.statement'] = statement.to_s
      expected_tags['error'] = true
      expected_tags['sfx.error.kind'] = error.class.to_s 
      expected_tags['sfx.error.message'] = error.to_s 
      expected_tags['sfx.error.stack'] = error.backtrace.join('\n') 

      expect(tracer.spans.last.tags).to eq expected_tags
      expect(tracer.spans.last.operation_name).to eq 'pg.query'
    end
  end
end
