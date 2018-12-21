local ffi = require('ffi')
local box = require('box')
local fiber = require('fiber')
local librdkafka = require('kafka.librdkafka')

local ConsumerConfig = {}

ConsumerConfig.__index = ConsumerConfig

function ConsumerConfig.create(brokers_list, consumer_group, enable_auto_commit)
    assert(brokers_list ~= nil)
    assert(consumer_group ~= nil)
    assert(enable_auto_commit ~= nil)

    local config = {
        _brokers_list = brokers_list,
        _consumer_group = consumer_group,
        _enable_auto_commit = enable_auto_commit,
        _options = {},
    }
    setmetatable(config, ConsumerConfig)
    return config
end

function ConsumerConfig:get_brokers_list()
    return self._brokers_list
end

function ConsumerConfig:get_consumer_group()
    return self._consumer_group
end

function ConsumerConfig:get_enable_auto_commit()
    return self._enable_auto_commit
end

function ConsumerConfig:set_option(name, value)
    self._options[name] = value
end

function ConsumerConfig:get_options()
    return self._options
end

local ConsumerMessage = {}

ConsumerMessage.__index = ConsumerMessage

function ConsumerMessage.create(rd_message)
    local msg = {
        _rd_message = rd_message,
        _value = nil,
        _topic = nil,
        _partition = nil,
        _offset = nil,
    }
    ffi.gc(msg._rd_message, function(...)
        librdkafka.rd_kafka_message_destroy(...)
    end)
    setmetatable(msg, ConsumerMessage)
    return msg
end

function ConsumerMessage:value()
    if self._value == nil then
        self._value = ffi.string(self._rd_message.payload)
    end
    return self._value
end

function ConsumerMessage:topic()
    if self._topic == nil then
        self._topic = ffi.string(librdkafka.rd_kafka_topic_name(self._rd_message.rkt))
    end
    return self._topic
end

function ConsumerMessage:partition()
    if self._partition == nil then
        self._partition = 1
    end
    return self._partition
end

function ConsumerMessage:offset()
    if self._offset == nil then
        self._offset = 1
    end
    return self._offset
end

local Consumer = {}

Consumer.__index = Consumer

function Consumer.create(config)
    assert(config ~= nil)

    local consumer = {
        config = config,
        _rd_consumer = {},
        _output_ch = nil,
    }
    setmetatable(consumer, Consumer)
    return consumer
end

function Consumer:_get_consumer_rd_config()
    local rd_config = librdkafka.rd_kafka_conf_new()

-- FIXME: почему мы здесь получаем segfault, а в продьюсере с таким же кодом все ок?
--    ffi.gc(rd_config, function (rd_config)
--        librdkafka.rd_kafka_conf_destroy(rd_config)
--    end)

    local ERRLEN = 256
    local errbuf = ffi.new("char[?]", ERRLEN) -- cdata objects are garbage collected
    if librdkafka.rd_kafka_conf_set(rd_config, "group.id", tostring(self.config:get_consumer_group()), errbuf, ERRLEN) ~= librdkafka.RD_KAFKA_CONF_OK then
        return nil, ffi.string(errbuf)
    end

    local enable_auto_commit
    if self.config:get_enable_auto_commit() then
        enable_auto_commit = "true"
    else
        enable_auto_commit = "false"
    end

    local ERRLEN = 256
    local errbuf = ffi.new("char[?]", ERRLEN) -- cdata objects are garbage collected
    if librdkafka.rd_kafka_conf_set(rd_config, "enable.auto.commit", enable_auto_commit, errbuf, ERRLEN) ~= librdkafka.RD_KAFKA_CONF_OK then
        return nil, ffi.string(errbuf)
    end

    for key, value in pairs(self.config:get_options()) do
        local errbuf = ffi.new("char[?]", ERRLEN) -- cdata objects are garbage collected
        if librdkafka.rd_kafka_conf_set(rd_config, key, tostring(value), errbuf, ERRLEN) ~= librdkafka.RD_KAFKA_CONF_OK then
            return nil, ffi.string(errbuf)
        end
    end

    librdkafka.rd_kafka_conf_set_consume_cb(rd_config,
        function(rkmessage)
            print(rkmessage)
            self._output_ch:put(ConsumerMessage.create(rkmessage))
        end)

    librdkafka.rd_kafka_conf_set_error_cb(rd_config,
        function(rk, err, reason)
            print("error", tonumber(err), ffi.string(reason))
        end)


    librdkafka.rd_kafka_conf_set_log_cb(rd_config,
        function(rk, level, fac, buf)
            print("log", tonumber(level), ffi.string(fac), ffi.string(buf))
        end)

    return rd_config, nil
end

function Consumer:_poll()
    while true do
        librdkafka.rd_kafka_poll(self._rd_consumer, 10)
        local rd_message = librdkafka.rd_kafka_consumer_poll(self._rd_consumer, 1000)
        print(rd_message)
        if rd_message ~= nil and rd_message.err ~= librdkafka.RD_KAFKA_RESP_ERR_NO_ERROR then
            -- FIXME: properly log this
            print(ffi.string(librdkafka.rd_kafka_err2str(rd_message.err)))
        end

        fiber.yield()
    end
end

jit.off(Consumer._poll)

function Consumer:start()
    local rd_config, err = self:_get_consumer_rd_config()
    if err ~= nil then
        return err
    end

    local ERRLEN = 256
    local errbuf = ffi.new("char[?]", ERRLEN) -- cdata objects are garbage collected
    local rd_consumer = librdkafka.rd_kafka_new(librdkafka.RD_KAFKA_CONSUMER, rd_config, errbuf, ERRLEN)
    if rd_consumer == nil then
        return ffi.string(errbuf)
    end

    -- redirect all events polling to rd_kafka_consumer_poll function
    local err = librdkafka.rd_kafka_poll_set_consumer(rd_consumer)
    if err ~= librdkafka.RD_KAFKA_RESP_ERR_NO_ERROR then
        return ffi.string(librdkafka.rd_kafka_err2str(err))
    end

    for _, broker in ipairs(self.config:get_brokers_list()) do
        if librdkafka.rd_kafka_brokers_add(rd_consumer, broker) < 1 then
            return "no valid brokers specified"
        end
    end

    self._rd_consumer = rd_consumer

    self._output_ch = fiber.channel(100)

    self._poll_fiber = fiber.create(function()
        self:_poll()
    end)
end

function Consumer:stop(timeout_ms)
    if self._rd_consumer == nil then
        return "'stop' method must be called only after consumer was started "
    end

    if timeout_ms == nil then
        timeout_ms = 1000
    end

    self._poll_fiber:cancel()
    self._output_ch:close()

    -- FIXME: handle this error
    local err = librdkafka.rd_kafka_consumer_close(self._rd_consumer)

    librdkafka.rd_kafka_destroy(self._rd_consumer)
    librdkafka.rd_kafka_wait_destroyed(timeout_ms)
    self._rd_consumer = nil

    return nil
end

function Consumer:subscribe(topics)
    if self._rd_consumer == nil then
        return "'add_topic' method must be called only after consumer was started "
    end

    local list = librdkafka.rd_kafka_topic_partition_list_new(#topics)
    for _, topic in ipairs(topics) do
        print(topic, librdkafka.RD_KAFKA_PARTITION_UA)
--        librdkafka.rd_kafka_topic_partition_list_add(list, topic, librdkafka.RD_KAFKA_PARTITION_UA)
        librdkafka.rd_kafka_topic_partition_list_add(list, topic, 0)
    end

    local err = nil
    local err_no = librdkafka.rd_kafka_subscribe(self._rd_consumer, list)
    if err_no ~= librdkafka.RD_KAFKA_RESP_ERR_NO_ERROR then
        err = ffi.string(librdkafka.rd_kafka_err2str(err_no))
    end

    librdkafka.rd_kafka_topic_partition_list_destroy(list)

    return err
end

function Consumer:output()
    if self._rd_consumer == nil then
        return nil, "'output' method must be called only after consumer was started "
    end

    return self._output_ch, nil
end

function Consumer:commit_async(message)
    if self._rd_consumer == nil then
        return "'commit' method must be called only after consumer was started "
    end

    local err_no = librdkafka.rd_kafka_commit_message(self._rd_consumer, message._rd_message, 1)
    if err_no ~= librdkafka.RD_KAFKA_RESP_ERR_NO_ERROR then
        return ffi.string(librdkafka.rd_kafka_err2str(err_no))
    end

    return nil
end

return {
    ConsumerConfig = ConsumerConfig,
    Consumer = Consumer,
}