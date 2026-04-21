# Symfony Messenger Reference

Complete guide for async message handling with Symfony Messenger in Symfony 7/8.

## Message Classes

Messages are simple, immutable DTOs:

```php
namespace App\Message;

final readonly class SendEmailNotification
{
    public function __construct(
        public int $userId,
        public string $subject,
        public string $content,
    ) {}
}
```

### Message with Complex Data

```php
final readonly class ProcessOrderMessage
{
    public function __construct(
        public int $orderId,
        public array $items,
        public \DateTimeImmutable $scheduledAt,
    ) {}
}
```

## Message Handlers

### Basic Handler

```php
namespace App\MessageHandler;

use App\Message\SendEmailNotification;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class SendEmailNotificationHandler
{
    public function __construct(
        private readonly MailerInterface $mailer,
        private readonly UserRepository $userRepository,
    ) {}

    public function __invoke(SendEmailNotification $message): void
    {
        $user = $this->userRepository->find($message->userId);

        $email = (new Email())
            ->to($user->getEmail())
            ->subject($message->subject)
            ->text($message->content);

        $this->mailer->send($email);
    }
}
```

### Handler with Return Value

```php
#[AsMessageHandler]
final class CalculateTaxHandler
{
    public function __invoke(CalculateTax $message): TaxResult
    {
        // Calculate and return result
        return new TaxResult(
            amount: $calculatedAmount,
            rate: $taxRate,
        );
    }
}
```

### Multiple Handlers for Same Message

```php
#[AsMessageHandler]
final class LogOrderHandler
{
    public function __invoke(OrderPlaced $message): void
    {
        // Log the order
    }
}

#[AsMessageHandler]
final class NotifyWarehouseHandler
{
    public function __invoke(OrderPlaced $message): void
    {
        // Notify warehouse
    }
}
```

## Dispatching Messages

### Synchronous Dispatch

```php
use Symfony\Component\Messenger\MessageBusInterface;

final class OrderService
{
    public function __construct(
        private readonly MessageBusInterface $messageBus,
    ) {}

    public function placeOrder(Order $order): void
    {
        // Save order...

        $this->messageBus->dispatch(new OrderPlaced($order->getId()));
    }
}
```

### Async Dispatch with Stamps

```php
use Symfony\Component\Messenger\Stamp\DelayStamp;
use Symfony\Component\Messenger\Stamp\TransportNamesStamp;

// Delay execution by 1 hour
$this->messageBus->dispatch(
    new SendReminder($userId),
    [new DelayStamp(3600000)] // milliseconds
);

// Route to specific transport
$this->messageBus->dispatch(
    new HeavyProcessing($data),
    [new TransportNamesStamp(['async_priority_high'])]
);
```

### Getting Results (Sync)

```php
use Symfony\Component\Messenger\Stamp\HandledStamp;

$envelope = $this->messageBus->dispatch(new CalculateTax($orderId));
$handledStamp = $envelope->last(HandledStamp::class);
$result = $handledStamp->getResult();
```

## Transport Configuration

### config/packages/messenger.yaml

```yaml
framework:
    messenger:
        # Failure transport for failed messages
        failure_transport: failed

        transports:
            # Async transport using Doctrine
            async:
                dsn: '%env(MESSENGER_TRANSPORT_DSN)%'
                retry_strategy:
                    max_retries: 3
                    delay: 1000
                    multiplier: 2
                    max_delay: 0

            # High priority async
            async_priority_high:
                dsn: '%env(MESSENGER_TRANSPORT_DSN)%'
                options:
                    queue_name: high

            # Failed messages storage
            failed:
                dsn: 'doctrine://default?queue_name=failed'

            # Sync transport for testing
            sync:
                dsn: 'sync://'

        routing:
            # Route messages to transports
            App\Message\SendEmailNotification: async
            App\Message\ProcessOrderMessage: async_priority_high
            App\Message\HeavyProcessing: async

        # Default settings
        default_bus: command.bus

        buses:
            command.bus:
                middleware:
                    - doctrine_transaction
            query.bus:
                middleware:
                    - validation
            event.bus:
                default_middleware:
                    enabled: true
                    allow_no_handlers: true
```

### Environment Variables

```bash
# .env
MESSENGER_TRANSPORT_DSN=doctrine://default

# Production with RabbitMQ
# MESSENGER_TRANSPORT_DSN=amqp://guest:guest@localhost:5672/%2f/messages

# Production with Redis
# MESSENGER_TRANSPORT_DSN=redis://localhost:6379/messages
```

## Running Workers

### Basic Worker

```bash
# Process messages from all transports
php bin/console messenger:consume async

# Process with memory limit
php bin/console messenger:consume async --memory-limit=128M

# Process with time limit
php bin/console messenger:consume async --time-limit=3600

# Process specific number of messages
php bin/console messenger:consume async --limit=10

# Multiple transports with priority
php bin/console messenger:consume async_priority_high async
```

### Supervisor Configuration

```ini
# /etc/supervisor/conf.d/messenger-worker.conf
[program:messenger-consume]
command=php /var/www/app/bin/console messenger:consume async --time-limit=3600
user=www-data
numprocs=2
startsecs=0
autostart=true
autorestart=true
process_name=%(program_name)s_%(process_num)02d
```

## Middleware

### Custom Middleware

```php
use Symfony\Component\Messenger\Envelope;
use Symfony\Component\Messenger\Middleware\MiddlewareInterface;
use Symfony\Component\Messenger\Middleware\StackInterface;

final class LoggingMiddleware implements MiddlewareInterface
{
    public function __construct(
        private readonly LoggerInterface $logger,
    ) {}

    public function handle(Envelope $envelope, StackInterface $stack): Envelope
    {
        $message = $envelope->getMessage();

        $this->logger->info('Handling message', [
            'class' => $message::class,
        ]);

        $startTime = microtime(true);

        try {
            $envelope = $stack->next()->handle($envelope, $stack);

            $this->logger->info('Message handled', [
                'class' => $message::class,
                'duration' => microtime(true) - $startTime,
            ]);

            return $envelope;
        } catch (\Throwable $e) {
            $this->logger->error('Message handling failed', [
                'class' => $message::class,
                'error' => $e->getMessage(),
            ]);

            throw $e;
        }
    }
}
```

### Register Middleware

```yaml
# config/packages/messenger.yaml
framework:
    messenger:
        buses:
            command.bus:
                middleware:
                    - App\Messenger\Middleware\LoggingMiddleware
                    - doctrine_transaction
```

## Handling Failures

### Retry Configuration

```yaml
framework:
    messenger:
        transports:
            async:
                dsn: '%env(MESSENGER_TRANSPORT_DSN)%'
                retry_strategy:
                    max_retries: 3
                    delay: 1000        # 1 second
                    multiplier: 2      # Exponential backoff
                    max_delay: 60000   # Max 1 minute
```

### Managing Failed Messages

```bash
# View failed messages
php bin/console messenger:failed:show

# Retry a specific failed message
php bin/console messenger:failed:retry 123

# Retry all failed messages
php bin/console messenger:failed:retry

# Remove a failed message
php bin/console messenger:failed:remove 123
```

### Custom Failure Handling

```php
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Symfony\Component\Messenger\Exception\UnrecoverableMessageHandlingException;

#[AsMessageHandler]
final class ProcessPaymentHandler
{
    public function __invoke(ProcessPayment $message): void
    {
        try {
            // Process payment...
        } catch (InvalidPaymentException $e) {
            // Don't retry - unrecoverable
            throw new UnrecoverableMessageHandlingException(
                'Invalid payment data',
                previous: $e
            );
        } catch (PaymentGatewayException $e) {
            // Will be retried
            throw $e;
        }
    }
}
```

## Scheduled Messages

### Using Scheduler

```php
use Symfony\Component\Scheduler\Attribute\AsSchedule;
use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\Schedule;
use Symfony\Component\Scheduler\ScheduleProviderInterface;

#[AsSchedule('default')]
final class AppScheduleProvider implements ScheduleProviderInterface
{
    public function getSchedule(): Schedule
    {
        return (new Schedule())
            ->add(
                RecurringMessage::every('1 hour', new CleanupTempFiles())
            )
            ->add(
                RecurringMessage::cron('0 0 * * *', new DailyReport())
            )
            ->add(
                RecurringMessage::every('5 minutes', new CheckPendingOrders())
            );
    }
}
```

## Testing Messenger

### Unit Testing Handlers

```php
final class SendEmailNotificationHandlerTest extends TestCase
{
    public function testHandlesSendEmail(): void
    {
        $mailer = $this->createMock(MailerInterface::class);
        $userRepository = $this->createMock(UserRepository::class);

        $user = new User();
        $user->setEmail('test@example.com');

        $userRepository->expects($this->once())
            ->method('find')
            ->with(1)
            ->willReturn($user);

        $mailer->expects($this->once())
            ->method('send')
            ->with($this->callback(function (Email $email) {
                return $email->getTo()[0]->getAddress() === 'test@example.com';
            }));

        $handler = new SendEmailNotificationHandler($mailer, $userRepository);
        $handler(new SendEmailNotification(1, 'Subject', 'Content'));
    }
}
```

### Integration Testing

```php
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Zenstruck\Messenger\Test\InteractsWithMessenger;

final class OrderServiceTest extends KernelTestCase
{
    use InteractsWithMessenger;

    public function testDispatchesOrderPlacedMessage(): void
    {
        $orderService = self::getContainer()->get(OrderService::class);

        $orderService->placeOrder($order);

        $this->messenger('async')
            ->queue()
            ->assertContains(OrderPlaced::class, 1);
    }

    public function testProcessesMessage(): void
    {
        $this->messenger('async')->dispatch(new OrderPlaced(1));

        $this->messenger('async')->process();

        // Assert side effects...
    }
}
```

## Best Practices

1. **Messages are immutable** - Use readonly classes
2. **One handler per message type** - Unless multiple handlers are intentional
3. **Keep handlers focused** - Single responsibility
4. **Use proper retry strategies** - Configure based on message type
5. **Monitor failed messages** - Set up alerts for the failed transport
6. **Test handlers in isolation** - Mock dependencies
7. **Use middleware for cross-cutting concerns** - Logging, transactions
8. **Serialize carefully** - Avoid entities in messages, use IDs
