local log = require("log")
local fiber = require('fiber')
local tnt_kafka = require("kafka.tntkafka")

local Consumer = {}

Consumer.__index = Consumer

function Consumer.create(config)
    if config == nil then
        return nil, "config must not be nil"
    end

    local consumer, err = tnt_kafka.create_consumer(config)
    if err ~= nil then
        return nil, err
    end

    local new = {
        config = config,
        _consumer = consumer,
        _output_ch = fiber.channel(10000),
    }
    setmetatable(new, Consumer)

    new._poll_msg_fiber = fiber.create(function()
        new:_poll_msg()
    end)

    if config.log_callback ~= nil then
        new._poll_logs_fiber = fiber.create(function()
            new:_poll_logs()
        end)
    end

    if config.error_callback ~= nil then
        new._poll_errors_fiber = fiber.create(function()
            new:_poll_errors()
        end)
    end

    if config.rebalance_callback ~= nil then
        new._poll_rebalances_fiber = fiber.create(function()
            new:_poll_rebalances()
        end)
    end

    return new, nil
end

function Consumer:_poll()
    local err
    while true do
        err = self._consumer:poll()
        if err ~= nil then
            log.error(err)
        end
    end
end

jit.off(Consumer._poll)

function Consumer:_poll_msg()
    local msgs
    while true do
        msgs = self._consumer:poll_msg(100)
        if #msgs > 0 then
            for _, msg in ipairs(msgs) do
                self._output_ch:put(msg)
            end
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(0.01)
        end
    end
end

jit.off(Consumer._poll_msg)

function Consumer:_poll_logs()
    local count, err
    while true do
        count, err = self._consumer:poll_logs(100)
        if err ~= nil then
            log.error("Consumer poll logs error: %s", err)
            -- throtling poll
            fiber.sleep(0.1)
        elseif count > 0 then
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(1)
        end
    end
end

jit.off(Consumer._poll_logs)

function Consumer:_poll_errors()
    local count, err
    while true do
        count, err = self._consumer:poll_errors(100)
        if err ~= nil then
            log.error("Consumer poll errors error: %s", err)
            -- throtling poll
            fiber.sleep(0.1)
        elseif count > 0 then
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(1)
        end
    end
end

jit.off(Consumer._poll_errors)

function Consumer:_poll_rebalances()
    local count, err
    while true do
        count, err = self._consumer:poll_rebalances(1)
        if err ~= nil then
            log.error("Consumer poll rebalances error: %s", err)
            -- throtling poll
            fiber.sleep(0.1)
        elseif count > 0 then
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(0.5)
        end
    end
end

jit.off(Consumer._poll_rebalances)

function Consumer:close()
    self._poll_msg_fiber:cancel()
    self._output_ch:close()

    fiber.yield()

    local ok, err = self._consumer:close()
    if err ~= nil then
        return ok, err
    end

    if self._poll_logs_fiber ~= nil then
        self._poll_logs_fiber:cancel()
    end
    if self._poll_errors_fiber ~= nil then
        self._poll_errors_fiber:cancel()
    end
    if self._poll_rebalances_fiber ~= nil then
        self._poll_rebalances_fiber:cancel()
    end

    self._consumer = nil

    return ok, err
end

function Consumer:subscribe(topics)
    return self._consumer:subscribe(topics)
end

function Consumer:unsubscribe(topics)
    return self._consumer:unsubscribe(topics)
end

function Consumer:output()
    return self._output_ch
end

function Consumer:store_offset(message)
    return self._consumer:store_offset(message)
end

local Producer = {}

Producer.__index = Producer

function Producer.create(config)
    if config == nil then
        return nil, "config must not be nil"
    end

    local producer, err = tnt_kafka.create_producer(config)
    if err ~= nil then
        return nil, err
    end

    local new = {
        config = config,
        _counter = 0,
        _delivery_map = {},
        _producer = producer,
    }
    setmetatable(new, Producer)

    new._msg_delivery_poll_fiber = fiber.create(function()
        new:_msg_delivery_poll()
    end)

    if config.log_callback ~= nil then
        new._poll_logs_fiber = fiber.create(function()
            new:_poll_logs()
        end)
    end

    if config.error_callback ~= nil then
        new._poll_errors_fiber = fiber.create(function()
            new:_poll_errors()
        end)
    end

    return new, nil
end

function Producer:_msg_delivery_poll()
    local count, err
    while true do
        local count, err
        while true do
            count, err = self._producer:msg_delivery_poll(100)
            if err ~= nil then
                log.error(err)
                -- throtling poll
                fiber.sleep(0.01)
            elseif count > 0 then
                fiber.yield()
            else
                -- throtling poll
                fiber.sleep(0.01)
            end
        end
    end
end

jit.off(Producer._msg_delivery_poll)

function Producer:_poll_logs()
    local count, err
    while true do
        count, err = self._producer:poll_logs(100)
        if err ~= nil then
            log.error("Producer poll logs error: %s", err)
            -- throtling poll
            fiber.sleep(0.1)
        elseif count > 0 then
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(1)
        end
    end
end

jit.off(Producer._poll_logs)

function Producer:_poll_errors()
    local count, err
    while true do
        count, err = self._producer:poll_errors(100)
        if err ~= nil then
            log.error("Producer poll errors error: %s", err)
            -- throtling poll
            fiber.sleep(0.1)
        elseif count > 0 then
            fiber.yield()
        else
            -- throtling poll
            fiber.sleep(1)
        end
    end
end

jit.off(Producer._poll_errors)

function Producer:produce_async(msg)
    local err = self._producer:produce(msg)
    return err
end

local function dr_callback_factory(delivery_chan)
    return function(err)
        delivery_chan:put(err)
    end
end

function Producer:produce(msg)
    local delivery_chan = fiber.channel(1)

    msg.dr_callback = dr_callback_factory(delivery_chan)

    local err = self._producer:produce(msg)
    if err == nil then
        err = delivery_chan:get()
    end

    return err
end

function Producer:close()
    local ok, err = self._producer:close()

    self._msg_delivery_poll_fiber:cancel()
    if self._poll_logs_fiber ~= nil then
        self._poll_logs_fiber:cancel()
    end
    if self._poll_errors_fiber ~= nil then
        self._poll_errors_fiber:cancel()
    end

    self._producer = nil

    return ok, err
end

return {
    Consumer = Consumer,
    Producer = Producer,
}
