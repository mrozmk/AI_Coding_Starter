---
name: Symfony Development
description: This skill should be used when the user asks to "create a Symfony controller", "add a Doctrine entity", "implement API Platform resource", "create a message handler", "add event listener", "implement voter", "write PHPUnit tests", "configure Symfony security", "create a service", "add form type", or works with Symfony 7.x/8.x, Doctrine ORM, API Platform, Messenger, or Security components. Provides comprehensive Symfony development guidance with SOLID principles and TDD.
version: 1.1.0
---

# Symfony Development Guide

This skill provides guidance for developing Symfony 7.x and 8.x applications with PHP 8.2+, following SOLID principles and test-driven development practices.

## Symfony 8 Ready

This guide follows Symfony 8 patterns:
- **PHP 8 Attributes only** - No XML or annotation configuration (XML support removed in Symfony 8)
- **Constructor property promotion** - Use `readonly` classes and properties
- **Strict typing** - Always use `declare(strict_types=1)`
- **Modern PHP** - Leverage PHP 8.2+ features (readonly classes, enums, named arguments)

## Core Principles

### SOLID in Symfony Context

**Single Responsibility**: Each class has one job
- Controllers: Handle HTTP, delegate to services
- Services: Business logic only
- Repositories: Data access only
- Entities: Data structure and validation

**Open/Closed**: Extend via interfaces and decorators
- Use Symfony's decorator pattern for service extension
- Leverage event system for extensibility

**Liskov Substitution**: Type-hint interfaces, not implementations
- Define service interfaces
- Use dependency injection with interface types

**Interface Segregation**: Small, focused interfaces
- Split large interfaces into role-specific ones
- Use PHP 8 intersection types when needed

**Dependency Inversion**: Inject abstractions
- Constructor injection always
- Autowire with interface bindings

### Test-Driven Development

Always write tests alongside implementation:

1. **Write test first** - Define expected behavior
2. **Run test (red)** - Verify it fails
3. **Implement code** - Make test pass
4. **Refactor** - Clean up while green
5. **Repeat** - Next feature

## Directory Structure

Standard Symfony project layout:

```
src/
├── Controller/          # HTTP controllers
├── Entity/              # Doctrine entities
├── Repository/          # Entity repositories
├── Service/             # Business logic services
├── Message/             # Messenger messages
├── MessageHandler/      # Message handlers
├── EventSubscriber/     # Event subscribers
├── Security/            # Voters, authenticators
├── Form/                # Form types
├── DTO/                 # Data transfer objects
└── ApiResource/         # API Platform resources (if separate)

tests/
├── Unit/                # Isolated unit tests
│   ├── Service/
│   └── Entity/
└── Integration/         # Integration/functional tests
    ├── Controller/
    └── Repository/
```

## Controllers

Keep controllers thin - delegate to services. Use PHP attributes for routing:

```php
<?php

declare(strict_types=1);

namespace App\Controller;

use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Attribute\MapRequestPayload;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/api/products', name: 'product_')]
final class ProductController extends AbstractController
{
    public function __construct(
        private readonly ProductServiceInterface $productService,
    ) {}

    #[Route('', methods: ['POST'])]
    public function create(#[MapRequestPayload] CreateProductDTO $dto): JsonResponse
    {
        $product = $this->productService->create($dto);

        return $this->json($product, Response::HTTP_CREATED);
    }
}
```

## Services

Business logic with interface-based design. Use `readonly` classes:

```php
<?php

declare(strict_types=1);

namespace App\Service;

interface ProductServiceInterface
{
    public function create(CreateProductDTO $dto): Product;
    public function findOrFail(int $id): Product;
}

final readonly class ProductService implements ProductServiceInterface
{
    public function __construct(
        private ProductRepository $repository,
        private EventDispatcherInterface $dispatcher,
    ) {}

    public function create(CreateProductDTO $dto): Product
    {
        $product = new Product(
            name: $dto->name,
            price: $dto->price,
        );

        $this->repository->save($product);
        $this->dispatcher->dispatch(new ProductCreatedEvent($product));

        return $product;
    }
}
```

## Entities

Use PHP 8 attributes for Doctrine mapping (no XML/YAML - attributes only):

```php
<?php

declare(strict_types=1);

namespace App\Entity;

use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity(repositoryClass: ProductRepository::class)]
#[ORM\Table(name: 'products')]
class Product
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    private ?int $id = null;

    #[ORM\Column(length: 255)]
    private string $name;

    #[ORM\Column(type: Types::DECIMAL, precision: 10, scale: 2)]
    private string $price;

    #[ORM\ManyToOne(targetEntity: Category::class, inversedBy: 'products')]
    #[ORM\JoinColumn(nullable: false)]
    private Category $category;

    #[ORM\OneToMany(targetEntity: Review::class, mappedBy: 'product', cascade: ['persist', 'remove'])]
    private Collection $reviews;

    public function __construct(string $name, string $price)
    {
        $this->name = $name;
        $this->price = $price;
        $this->reviews = new ArrayCollection();
    }

    // Getters and setters...
}
```

## Repositories

Extend ServiceEntityRepository with custom queries:

```php
<?php

declare(strict_types=1);

namespace App\Repository;

/**
 * @extends ServiceEntityRepository<Product>
 */
class ProductRepository extends ServiceEntityRepository
{
    public function __construct(ManagerRegistry $registry)
    {
        parent::__construct($registry, Product::class);
    }

    public function save(Product $product, bool $flush = true): void
    {
        $this->getEntityManager()->persist($product);
        if ($flush) {
            $this->getEntityManager()->flush();
        }
    }

    /**
     * @return Product[]
     */
    public function findByCategory(Category $category): array
    {
        return $this->createQueryBuilder('p')
            ->andWhere('p.category = :category')
            ->setParameter('category', $category)
            ->orderBy('p.name', 'ASC')
            ->getQuery()
            ->getResult();
    }
}
```

## Testing

### Unit Tests

Test services in isolation with mocks:

```php
<?php

declare(strict_types=1);

namespace App\Tests\Unit\Service;

final class ProductServiceTest extends TestCase
{
    private ProductServiceInterface $service;
    private ProductRepository&MockObject $repository;
    private EventDispatcherInterface&MockObject $dispatcher;

    protected function setUp(): void
    {
        $this->repository = $this->createMock(ProductRepository::class);
        $this->dispatcher = $this->createMock(EventDispatcherInterface::class);

        $this->service = new ProductService(
            $this->repository,
            $this->dispatcher,
        );
    }

    public function testCreateProduct(): void
    {
        // Arrange
        $dto = new CreateProductDTO(name: 'Test', price: '99.99');

        $this->repository->expects($this->once())
            ->method('save')
            ->with($this->isInstanceOf(Product::class));

        $this->dispatcher->expects($this->once())
            ->method('dispatch')
            ->with($this->isInstanceOf(ProductCreatedEvent::class));

        // Act
        $product = $this->service->create($dto);

        // Assert
        $this->assertSame('Test', $product->getName());
        $this->assertSame('99.99', $product->getPrice());
    }
}
```

### Integration Tests

Test controllers with WebTestCase:

```php
<?php

declare(strict_types=1);

namespace App\Tests\Integration\Controller;

final class ProductControllerTest extends WebTestCase
{
    use ResetDatabaseTrait;

    public function testCreateProduct(): void
    {
        $client = static::createClient();

        $client->request('POST', '/api/products', [], [], [
            'CONTENT_TYPE' => 'application/json',
        ], json_encode([
            'name' => 'New Product',
            'price' => '49.99',
            'categoryId' => 1,
        ]));

        $this->assertResponseStatusCodeSame(201);
        $this->assertJson($client->getResponse()->getContent());

        $data = json_decode($client->getResponse()->getContent(), true);
        $this->assertSame('New Product', $data['name']);
    }
}
```

### Running Tests

Before any commit, run the full test suite:

```bash
# Run all tests
php bin/phpunit

# Run specific test file
php bin/phpunit tests/Unit/Service/ProductServiceTest.php

# Run with coverage
php bin/phpunit --coverage-html coverage/
```

## Pre-Commit Workflow

1. Make code changes
2. Write/update tests
3. Run `php bin/phpunit`
4. Fix any failures
5. Only commit when ALL tests pass

## Using Context7 for Documentation

When needing up-to-date documentation:

1. Use `resolve-library-id` to find library:
   - "symfony/symfony" for Symfony docs
   - "api-platform/core" for API Platform
   - "doctrine/orm" for Doctrine

2. Use `query-docs` with specific questions:
   - "How to create a custom voter in Symfony 8"
   - "API Platform custom operations"
   - "Doctrine lifecycle callbacks"

## Additional Resources

### Reference Files

For detailed component guidance, consult:

- **`references/api-platform.md`** - API Platform resources, operations, DTOs
- **`references/messenger.md`** - Message handlers, transports, middleware
- **`references/security.md`** - Voters, authenticators, firewalls
- **`references/events.md`** - Event subscribers, custom events
- **`references/testing.md`** - PHPUnit patterns, fixtures, mocking

### Quick Reference

| Component | Location | Pattern |
|-----------|----------|---------|
| Controllers | `src/Controller/` | Thin, delegate to services |
| Services | `src/Service/` | Interface + readonly implementation |
| Entities | `src/Entity/` | PHP 8 attributes only |
| Repositories | `src/Repository/` | Custom query methods |
| Messages | `src/Message/` | Immutable readonly DTOs |
| Handlers | `src/MessageHandler/` | Single handler per message |
| Voters | `src/Security/` | Granular authorization |
| Events | `src/EventSubscriber/` | Subscribers over listeners |
| Tests | `tests/Unit/`, `tests/Integration/` | AAA pattern |
