# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.expand_path(File.join(__FILE__, "..", "app", "models", "models"))

class ActiveRecordInstrumentationTest < Minitest::Test

  include MultiverseHelpers
  setup_and_teardown_agent

  def after_setup
    super
    NewRelic::Agent.drop_buffered_data
  end

  def test_metrics_for_create
    in_web_transaction do
      Order.create(:name => 'bob')
    end

    if active_record_major_version >= 3
      assert_generic_rollup_metrics('insert')
    else
      assert_activerecord_metrics(Order, 'create')
    end
  end

  def test_metrics_for_create_via_association
    in_web_transaction do
      order = Order.create(:name => 'bob')
      order.shipments.create
      order.shipments.to_a
    end

    assert_generic_rollup_metrics('insert')
  end

  def test_metrics_for_find
    in_web_transaction do
      if active_record_major_version >= 4
        Order.where(:name => 'foo').load
      else
        Order.find_all_by_name('foo')
      end
    end

    assert_activerecord_metrics(Order, 'find')
  end

  def test_metrics_for_find_via_association
    in_web_transaction do
      order = Order.create(:name => 'bob')
      order.shipments.create
      order.shipments.to_a
    end

    assert_activerecord_metrics(Shipment, 'find')
  end

  def test_metrics_for_find_all
    in_web_transaction do
      case
      when active_record_major_version >= 4
        Order.all.load
      when active_record_major_version >= 3
        Order.all
      else
        Order.find(:all)
      end
    end

    assert_activerecord_metrics(Order, 'find')
  end

  def test_metrics_for_find_via_named_scope
    major_version = active_record_major_version
    minor_version = active_record_minor_version
    Order.class_eval do
      if major_version >= 4
        scope :jeffs, lambda { where(:name => 'Jeff') }
      elsif major_version == 3 && minor_version >= 1
        scope :jeffs, :conditions => { :name => 'Jeff' }
      else
        named_scope :jeffs, :conditions => { :name => 'Jeff' }
      end
    end

    in_web_transaction do
      if active_record_major_version >= 4
        Order.jeffs.load
      else
        Order.jeffs.find(:all)
      end
    end

    assert_activerecord_metrics(Order, 'find')
  end

  def test_metrics_for_exists
    in_web_transaction do
      Order.exists?(["name=?", "jeff"])
    end

    if active_record_major_version == 3 && [0,1].include?(active_record_minor_version)
      # Bugginess in Rails 3.0 and 3.1 doesn't let us get ActiveRecord/find
      assert_generic_rollup_metrics('select')
    else
      assert_activerecord_metrics(Order, 'find')
    end
  end

  def test_metrics_for_update
    in_web_transaction do
      order = Order.create(:name => "wendy")
      order.name = 'walter'
      order.save
    end

    assert_generic_rollup_metrics('update')
  end

  def test_metrics_for_destroy
    in_web_transaction do
      order = Order.create("name" => "burt")
      order.destroy
    end

    if active_record_major_version >= 3
      assert_generic_rollup_metrics('delete')
    else
      assert_activerecord_metrics(Order, 'destroy')
    end
  end

  def test_metrics_for_direct_sql_select
    in_web_transaction do
      conn = Order.connection
      conn.select_rows("SELECT * FROM #{Order.table_name}")
    end

    assert_generic_rollup_metrics('select')
  end

  def test_metrics_for_direct_sql_other
    in_web_transaction do
      conn = Order.connection
      conn.execute("begin")
      conn.execute("commit")
    end

    assert_generic_rollup_metrics('other')
  end

  def test_metrics_for_direct_sql_show
    if supports_show_tables?
      in_web_transaction do
        conn = Order.connection
        conn.execute("show tables")
      end

      assert_generic_rollup_metrics('show')
    end
  end

  def test_still_records_metrics_in_error_cases
    # have the AR select throw an error
    Order.connection.stubs(:log_info).with do |sql, *|
      raise "Error" if sql =~ /select/
      true
    end

    in_web_transaction do
      begin
        Order.connection.select_rows "select * from #{Order.table_name}"
      rescue RuntimeError => e
        # catch only the error we raise above
        raise unless e.message == 'Error'
      end
    end

    assert_generic_rollup_metrics('select')
  end

  def test_passes_through_errors
    begin
      Order.transaction do
        raise ActiveRecord::ActiveRecordError.new('preserve-me!')
      end
    rescue ActiveRecord::ActiveRecordError => e
      assert_equal 'preserve-me!', e.message
    end
  end

  def test_no_metrics_recorded_with_disable_all_tracing
    NewRelic::Agent.disable_all_tracing do
      in_web_transaction('bogosity') do
        Order.first
      end
    end
    assert_nil NewRelic::Agent.instance.transaction_sampler.last_sample
    assert_metrics_recorded_exclusive([])
  end

  def test_records_transaction_trace_nodes
    in_web_transaction do
      Order.first
    end
    sample = NewRelic::Agent.instance.transaction_sampler.last_sample
    metric = "Datastore/statement/#{current_product}/Order/find"
    node = find_node_with_name(sample, metric)
    assert_equal(metric, node.metric_name)

    sql = node.params[:sql]
    assert_match(/^SELECT /, sql)

    assert_equal(adapter.to_s, sql.adapter)
    refute_nil(sql.config)
    refute_nil(sql.explainer)
  end

  def test_gathers_explain_plans
    with_config(:'transaction_tracer.explain_threshold' => -0.1) do
      in_web_transaction do
        Order.first
      end

      sample = NewRelic::Agent.instance.transaction_sampler.last_sample
      metric = "Datastore/statement/#{current_product}/Order/find"
      sql_node = find_node_with_name(sample, metric)

      assert_match(/^SELECT /, sql_node.params[:sql])

      sample.prepare_to_send!
      explanations = sql_node.params[:explain_plan]
      if supports_explain_plans?
        refute_nil explanations, "No explains in node: #{sql_node}"
        assert_equal(2, explanations.size,
                     "No explains in node: #{sql_node}")
      end
    end
  end

  def test_sql_samplers_get_proper_metrics
    with_config(:'transaction_tracer.explain_threshold' => -0.1) do
      in_web_transaction do
        Order.first
      end

      metric = "Datastore/statement/#{current_product}/Order/find"
      refute_nil find_sql_trace(metric)
    end
  end

  def test_records_metrics_on_background_transaction
    in_transaction('back it up') do
      Order.create(:name => 'bob')
    end

    assert_metrics_recorded(['Datastore/all', 'Datastore/allOther'])
    assert_metrics_not_recorded(['Datastore/allWeb'])
  end

  def test_cached_calls_are_not_recorded_with_find
    in_web_transaction do
      order = Order.create(:name => 'Oberon')
      Order.connection.cache do
        Order.find(order.id)
        Order.find(order.id)
        Order.find(order.id)
      end
    end

    assert_activerecord_metrics(Order, 'find', :call_count => 1)
  end

  def test_cached_calls_are_not_recorded_with_select_all
    # If this is the first create, ActiveRecord needs to warm up,
    # send some SQL SELECTS, etc.
    in_web_transaction do
      Order.create(:name => 'Oberon')
    end
    NewRelic::Agent.drop_buffered_data

    # the actual test is here
    query = "SELECT * FROM #{Order.table_name} WHERE name = 'Oberon'"
    in_web_transaction do
      Order.connection.cache do
        Order.connection.select_all(query)
        Order.connection.select_all(query)
        Order.connection.select_all(query)
      end
    end

    assert_metrics_recorded(
      {"Datastore/operation/#{current_product}/select" => {:call_count => 1}}
    )
  end

  def test_with_database_metric_name
    in_web_transaction do
      Order.create(:name => "eely")
      NewRelic::Agent.with_database_metric_name('Eel', 'squirm') do
        Order.connection.select_rows("SELECT id FROM #{Order.table_name}")
      end
    end

    assert_metrics_recorded(
      {
        "Datastore/statement/#{current_product}/Eel/squirm" => {:call_count => 1},
        "Datastore/operation/#{current_product}/squirm" => {:call_count => 1}
      })
  end

  ## helpers

  def adapter
    adapter_string = Order.configurations[RAILS_ENV]['adapter']
    adapter_string.downcase.to_sym
  end

  def supports_show_tables?
    [:mysql, :postgres].include?(adapter)
  end

  def supports_explain_plans?
    [:mysql, :postgres].include?(adapter)
  end

  def current_product
    NewRelic::Agent::Instrumentation::ActiveRecordHelper::PRODUCT_NAMES[adapter.to_s]
  end

  def active_record_major_version
    if defined?(::ActiveRecord::VERSION::MAJOR)
      ::ActiveRecord::VERSION::MAJOR.to_i
    else
      2
    end
  end

  def active_record_minor_version
    if defined?(::ActiveRecord::VERSION::MINOR)
      ::ActiveRecord::VERSION::MINOR.to_i
    else
      1
    end
  end

  def active_record_version
    if defined?(::ActiveRecord::VERSION::MINOR)
      NewRelic::VersionNumber.new(::ActiveRecord::VERSION::STRING)
    else
      NewRelic::VersionNumber.new("2.1.0")  # Can't tell between 2.1 and 2.2. Meh.
    end
  end

  def assert_activerecord_metrics(model, operation, stats={})
    assert_metrics_recorded({
      "Datastore/statement/#{current_product}/#{model}/#{operation}" => stats,
      "Datastore/operation/#{current_product}/#{operation}" => {},
      "Datastore/allWeb" => {},
      "Datastore/all" => {}
    })
  end

  def assert_generic_rollup_metrics(operation)
    assert_metrics_recorded([
      "Datastore/operation/#{current_product}/#{operation}",
      "Datastore/allWeb",
      "Datastore/all"
    ])
  end
end
