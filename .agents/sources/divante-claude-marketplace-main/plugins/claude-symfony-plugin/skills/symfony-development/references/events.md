# Symfony Events Reference

Complete guide for event-driven architecture in Symfony 7/8.

## Event Subscribers vs Listeners

**Prefer Event Subscribers** - they are self-contained and define their own subscriptions.

| Feature | Subscriber | Listener |
|---------|------------|----------|
| Configuration | In class | In YAML |
| Multiple events | Easy | Requires multiple tags |
| Priority control | In class | In configuration |
| Testability | Easier | Requires container |

## Creating Event Subscribers

### Basic Subscriber

```php
namespace App\EventSubscriber;

use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\KernelEvents;

final class LocaleSubscriber implements EventSubscriberInterface
{
    public function __construct(
        private readonly string $defaultLocale = 'en',
    ) {}

    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::REQUEST => [
                ['onKernelRequest', 20], // Priority 20
            ],
        ];
    }

    public function onKernelRequest(RequestEvent $event): void
    {
        $request = $event->getRequest();

        if (!$request->hasPreviousSession()) {
            return;
        }

        $locale = $request->getSession()->get('_locale', $this->defaultLocale);
        $request->setLocale($locale);
    }
}
```

### Multiple Events Subscriber

```php
namespace App\EventSubscriber;

use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpKernel\Event\ExceptionEvent;
use Symfony\Component\HttpKernel\Event\ResponseEvent;
use Symfony\Component\HttpKernel\KernelEvents;

final class ApiResponseSubscriber implements EventSubscriberInterface
{
    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::RESPONSE => ['onResponse', 0],
            KernelEvents::EXCEPTION => ['onException', -10],
        ];
    }

    public function onResponse(ResponseEvent $event): void
    {
        $response = $event->getResponse();
        $response->headers->set('X-Api-Version', '1.0');
    }

    public function onException(ExceptionEvent $event): void
    {
        // Handle API exceptions
    }
}
```

## Custom Events

### Creating a Custom Event

```php
namespace App\Event;

use App\Entity\User;
use Symfony\Contracts\EventDispatcher\Event;

final class UserRegisteredEvent extends Event
{
    public const NAME = 'user.registered';

    public function __construct(
        private readonly User $user,
        private readonly bool $emailVerificationRequired = true,
    ) {}

    public function getUser(): User
    {
        return $this->user;
    }

    public function isEmailVerificationRequired(): bool
    {
        return $this->emailVerificationRequired;
    }
}
```

### Dispatching Custom Events

```php
namespace App\Service;

use App\Event\UserRegisteredEvent;
use Symfony\Contracts\EventDispatcher\EventDispatcherInterface;

final class RegistrationService
{
    public function __construct(
        private readonly UserRepository $repository,
        private readonly EventDispatcherInterface $dispatcher,
    ) {}

    public function register(RegistrationDTO $dto): User
    {
        $user = new User();
        $user->setEmail($dto->email);
        $user->setName($dto->name);

        $this->repository->save($user);

        // Dispatch the event
        $event = new UserRegisteredEvent($user);
        $this->dispatcher->dispatch($event, UserRegisteredEvent::NAME);

        return $user;
    }
}
```

### Subscribing to Custom Events

```php
namespace App\EventSubscriber;

use App\Event\UserRegisteredEvent;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;

final class UserRegistrationSubscriber implements EventSubscriberInterface
{
    public function __construct(
        private readonly MailerInterface $mailer,
        private readonly LoggerInterface $logger,
    ) {}

    public static function getSubscribedEvents(): array
    {
        return [
            UserRegisteredEvent::NAME => [
                ['sendWelcomeEmail', 10],
                ['logRegistration', 0],
                ['notifyAdmin', -10],
            ],
        ];
    }

    public function sendWelcomeEmail(UserRegisteredEvent $event): void
    {
        if (!$event->isEmailVerificationRequired()) {
            return;
        }

        $user = $event->getUser();
        // Send welcome email...
    }

    public function logRegistration(UserRegisteredEvent $event): void
    {
        $this->logger->info('New user registered', [
            'email' => $event->getUser()->getEmail(),
        ]);
    }

    public function notifyAdmin(UserRegisteredEvent $event): void
    {
        // Notify admin of new registration...
    }
}
```

## Kernel Events

### Common Kernel Events

| Event | When | Use Case |
|-------|------|----------|
| `kernel.request` | Before controller | Authentication, locale, routing |
| `kernel.controller` | Before action | Modify controller/arguments |
| `kernel.view` | After non-Response return | Template rendering |
| `kernel.response` | Before sending response | Add headers, modify response |
| `kernel.finish_request` | After response sent | Cleanup |
| `kernel.terminate` | After response sent | Async tasks |
| `kernel.exception` | On exception | Error handling |

### Request Event Example

```php
final class MaintenanceModeSubscriber implements EventSubscriberInterface
{
    public function __construct(
        private readonly bool $maintenanceMode,
    ) {}

    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::REQUEST => ['onRequest', 100], // High priority
        ];
    }

    public function onRequest(RequestEvent $event): void
    {
        if (!$this->maintenanceMode) {
            return;
        }

        if (!$event->isMainRequest()) {
            return;
        }

        // Allow admin access
        if (str_starts_with($event->getRequest()->getPathInfo(), '/admin')) {
            return;
        }

        throw new ServiceUnavailableHttpException(
            null,
            'Site is under maintenance'
        );
    }
}
```

### Exception Event Example

```php
final class ApiExceptionSubscriber implements EventSubscriberInterface
{
    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::EXCEPTION => ['onException', 0],
        ];
    }

    public function onException(ExceptionEvent $event): void
    {
        $request = $event->getRequest();

        // Only handle API routes
        if (!str_starts_with($request->getPathInfo(), '/api')) {
            return;
        }

        $exception = $event->getThrowable();

        $statusCode = $exception instanceof HttpExceptionInterface
            ? $exception->getStatusCode()
            : Response::HTTP_INTERNAL_SERVER_ERROR;

        $response = new JsonResponse([
            'error' => [
                'code' => $statusCode,
                'message' => $exception->getMessage(),
            ],
        ], $statusCode);

        $event->setResponse($response);
    }
}
```

## Doctrine Events

### Lifecycle Callbacks (Entity-level)

```php
#[ORM\Entity]
#[ORM\HasLifecycleCallbacks]
class Article
{
    #[ORM\Column(type: Types::DATETIME_IMMUTABLE)]
    private \DateTimeImmutable $createdAt;

    #[ORM\Column(type: Types::DATETIME_IMMUTABLE)]
    private \DateTimeImmutable $updatedAt;

    #[ORM\PrePersist]
    public function setCreatedAtValue(): void
    {
        $this->createdAt = new \DateTimeImmutable();
        $this->updatedAt = new \DateTimeImmutable();
    }

    #[ORM\PreUpdate]
    public function setUpdatedAtValue(): void
    {
        $this->updatedAt = new \DateTimeImmutable();
    }
}
```

### Entity Listeners (Service-level)

```php
namespace App\EventListener;

use App\Entity\Product;
use Doctrine\Bundle\DoctrineBundle\Attribute\AsEntityListener;
use Doctrine\ORM\Events;

#[AsEntityListener(event: Events::prePersist, entity: Product::class)]
#[AsEntityListener(event: Events::preUpdate, entity: Product::class)]
final class ProductListener
{
    public function prePersist(Product $product): void
    {
        $product->setSlug($this->generateSlug($product->getName()));
    }

    public function preUpdate(Product $product): void
    {
        $product->setSlug($this->generateSlug($product->getName()));
    }

    private function generateSlug(string $name): string
    {
        return strtolower(preg_replace('/[^a-zA-Z0-9]+/', '-', $name));
    }
}
```

### Doctrine Event Subscribers

```php
namespace App\EventSubscriber;

use Doctrine\Bundle\DoctrineBundle\Attribute\AsDoctrineListener;
use Doctrine\ORM\Event\PostPersistEventArgs;
use Doctrine\ORM\Events;

#[AsDoctrineListener(event: Events::postPersist)]
final class AuditLogSubscriber
{
    public function __construct(
        private readonly AuditLogger $auditLogger,
    ) {}

    public function postPersist(PostPersistEventArgs $args): void
    {
        $entity = $args->getObject();

        $this->auditLogger->log('create', $entity::class, [
            'id' => $entity->getId(),
        ]);
    }
}
```

## Stoppable Events

```php
use Psr\EventDispatcher\StoppableEventInterface;

final class OrderValidationEvent extends Event implements StoppableEventInterface
{
    private bool $propagationStopped = false;
    private array $errors = [];

    public function __construct(
        private readonly Order $order,
    ) {}

    public function addError(string $error): void
    {
        $this->errors[] = $error;
        $this->propagationStopped = true;
    }

    public function getErrors(): array
    {
        return $this->errors;
    }

    public function isPropagationStopped(): bool
    {
        return $this->propagationStopped;
    }
}
```

## Event Priority

```php
public static function getSubscribedEvents(): array
{
    return [
        KernelEvents::REQUEST => [
            ['highPriority', 100],    // Runs first
            ['normalPriority', 0],    // Default
            ['lowPriority', -100],    // Runs last
        ],
    ];
}
```

**Priority guidelines:**
- `> 0`: Run before default handlers
- `0`: Normal priority
- `< 0`: Run after default handlers
- Security: typically 8-9
- Router: typically 32

## Testing Events

### Testing Event Dispatch

```php
final class RegistrationServiceTest extends TestCase
{
    public function testDispatchesUserRegisteredEvent(): void
    {
        $dispatcher = $this->createMock(EventDispatcherInterface::class);
        $repository = $this->createMock(UserRepository::class);

        $dispatcher->expects($this->once())
            ->method('dispatch')
            ->with(
                $this->isInstanceOf(UserRegisteredEvent::class),
                UserRegisteredEvent::NAME
            );

        $service = new RegistrationService($repository, $dispatcher);
        $service->register(new RegistrationDTO('test@example.com', 'Test'));
    }
}
```

### Testing Subscribers

```php
final class UserRegistrationSubscriberTest extends TestCase
{
    public function testSendWelcomeEmail(): void
    {
        $mailer = $this->createMock(MailerInterface::class);
        $logger = $this->createMock(LoggerInterface::class);

        $mailer->expects($this->once())
            ->method('send');

        $subscriber = new UserRegistrationSubscriber($mailer, $logger);

        $user = new User();
        $user->setEmail('test@example.com');
        $event = new UserRegisteredEvent($user);

        $subscriber->sendWelcomeEmail($event);
    }

    public function testSkipsEmailWhenNotRequired(): void
    {
        $mailer = $this->createMock(MailerInterface::class);
        $logger = $this->createMock(LoggerInterface::class);

        $mailer->expects($this->never())
            ->method('send');

        $subscriber = new UserRegistrationSubscriber($mailer, $logger);

        $user = new User();
        $event = new UserRegisteredEvent($user, emailVerificationRequired: false);

        $subscriber->sendWelcomeEmail($event);
    }
}
```

## Best Practices

1. **Use subscribers over listeners** - Self-contained, easier to test
2. **Keep handlers focused** - Single responsibility per method
3. **Use meaningful event names** - `user.registered` not `event1`
4. **Document event flow** - Complex flows need documentation
5. **Consider priority carefully** - Document why specific priorities
6. **Make events immutable** - Use readonly properties
7. **Test event dispatch** - Verify events are dispatched
8. **Test handlers in isolation** - Mock dependencies
9. **Use stoppable events** - When validation can fail early
10. **Avoid circular dispatching** - Don't dispatch from handlers carelessly
