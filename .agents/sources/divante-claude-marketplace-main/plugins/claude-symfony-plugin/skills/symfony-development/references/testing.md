# PHPUnit Testing Reference

Complete guide for testing Symfony 7 applications with PHPUnit.

## Test Organization

```
tests/
├── Unit/                    # Isolated unit tests
│   ├── Service/
│   │   └── ProductServiceTest.php
│   ├── Entity/
│   │   └── ProductTest.php
│   └── Validator/
│       └── ProductValidatorTest.php
├── Integration/             # Tests with database/services
│   ├── Repository/
│   │   └── ProductRepositoryTest.php
│   └── Service/
│       └── OrderServiceTest.php
└── Functional/              # Full HTTP request tests
    ├── Controller/
    │   └── ProductControllerTest.php
    └── Api/
        └── ProductApiTest.php
```

## Unit Tests

### Basic Unit Test

```php
namespace App\Tests\Unit\Service;

use App\Service\PriceCalculator;
use PHPUnit\Framework\TestCase;

final class PriceCalculatorTest extends TestCase
{
    private PriceCalculator $calculator;

    protected function setUp(): void
    {
        $this->calculator = new PriceCalculator();
    }

    public function testCalculateWithoutDiscount(): void
    {
        // Arrange
        $basePrice = 100.00;
        $quantity = 2;

        // Act
        $result = $this->calculator->calculate($basePrice, $quantity);

        // Assert
        $this->assertSame(200.00, $result);
    }

    public function testCalculateWithDiscount(): void
    {
        $result = $this->calculator->calculate(100.00, 2, discountPercent: 10);

        $this->assertSame(180.00, $result);
    }

    public function testThrowsOnNegativePrice(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessage('Price must be positive');

        $this->calculator->calculate(-10.00, 1);
    }
}
```

### Testing with Mocks

```php
namespace App\Tests\Unit\Service;

use App\Entity\Order;
use App\Repository\OrderRepository;
use App\Service\NotificationService;
use App\Service\OrderService;
use PHPUnit\Framework\MockObject\MockObject;
use PHPUnit\Framework\TestCase;

final class OrderServiceTest extends TestCase
{
    private OrderService $service;
    private OrderRepository&MockObject $repository;
    private NotificationService&MockObject $notifier;

    protected function setUp(): void
    {
        $this->repository = $this->createMock(OrderRepository::class);
        $this->notifier = $this->createMock(NotificationService::class);

        $this->service = new OrderService(
            $this->repository,
            $this->notifier,
        );
    }

    public function testCompleteOrderSavesAndNotifies(): void
    {
        // Arrange
        $order = new Order();

        $this->repository->expects($this->once())
            ->method('save')
            ->with($order);

        $this->notifier->expects($this->once())
            ->method('sendOrderConfirmation')
            ->with($order);

        // Act
        $this->service->complete($order);

        // Assert
        $this->assertSame('completed', $order->getStatus());
    }

    public function testFindByIdReturnsOrder(): void
    {
        $order = new Order();

        $this->repository->expects($this->once())
            ->method('find')
            ->with(123)
            ->willReturn($order);

        $result = $this->service->findById(123);

        $this->assertSame($order, $result);
    }

    public function testFindByIdThrowsWhenNotFound(): void
    {
        $this->repository->method('find')
            ->willReturn(null);

        $this->expectException(OrderNotFoundException::class);

        $this->service->findById(999);
    }
}
```

### Testing with Data Providers

```php
final class EmailValidatorTest extends TestCase
{
    private EmailValidator $validator;

    protected function setUp(): void
    {
        $this->validator = new EmailValidator();
    }

    /**
     * @dataProvider validEmailProvider
     */
    public function testValidEmails(string $email): void
    {
        $this->assertTrue($this->validator->isValid($email));
    }

    /**
     * @dataProvider invalidEmailProvider
     */
    public function testInvalidEmails(string $email): void
    {
        $this->assertFalse($this->validator->isValid($email));
    }

    public static function validEmailProvider(): array
    {
        return [
            'simple' => ['test@example.com'],
            'with subdomain' => ['test@mail.example.com'],
            'with plus' => ['test+tag@example.com'],
            'with dots' => ['first.last@example.com'],
        ];
    }

    public static function invalidEmailProvider(): array
    {
        return [
            'no at' => ['testexample.com'],
            'no domain' => ['test@'],
            'spaces' => ['test @example.com'],
            'double at' => ['test@@example.com'],
        ];
    }
}
```

## Integration Tests

### Repository Tests

```php
namespace App\Tests\Integration\Repository;

use App\Entity\Product;
use App\Repository\ProductRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

final class ProductRepositoryTest extends KernelTestCase
{
    private EntityManagerInterface $entityManager;
    private ProductRepository $repository;

    protected function setUp(): void
    {
        self::bootKernel();

        $this->entityManager = static::getContainer()
            ->get('doctrine')
            ->getManager();

        $this->repository = static::getContainer()->get(ProductRepository::class);

        // Clean up database
        $this->entityManager->createQuery('DELETE FROM App\Entity\Product')->execute();
    }

    public function testSaveAndFind(): void
    {
        $product = new Product('Test Product', '99.99');

        $this->repository->save($product);

        $found = $this->repository->find($product->getId());

        $this->assertNotNull($found);
        $this->assertSame('Test Product', $found->getName());
    }

    public function testFindByCategory(): void
    {
        // Create test data
        $category = new Category('Electronics');
        $this->entityManager->persist($category);

        $product1 = new Product('Phone', '499.99');
        $product1->setCategory($category);
        $product2 = new Product('Laptop', '999.99');
        $product2->setCategory($category);

        $this->entityManager->persist($product1);
        $this->entityManager->persist($product2);
        $this->entityManager->flush();

        // Test
        $products = $this->repository->findByCategory($category);

        $this->assertCount(2, $products);
    }

    protected function tearDown(): void
    {
        parent::tearDown();
        $this->entityManager->close();
    }
}
```

### Service Integration Tests

```php
namespace App\Tests\Integration\Service;

use App\Service\PaymentService;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;

final class PaymentServiceTest extends KernelTestCase
{
    private PaymentService $paymentService;

    protected function setUp(): void
    {
        self::bootKernel();
        $container = static::getContainer();

        $this->paymentService = $container->get(PaymentService::class);
    }

    public function testProcessPayment(): void
    {
        $result = $this->paymentService->process(
            amount: 100.00,
            currency: 'USD',
            cardToken: 'test_token'
        );

        $this->assertTrue($result->isSuccessful());
    }
}
```

## Functional Tests

### Controller Tests

```php
namespace App\Tests\Functional\Controller;

use App\Entity\User;
use Symfony\Bundle\FrameworkBundle\Test\WebTestCase;

final class ProductControllerTest extends WebTestCase
{
    public function testListProducts(): void
    {
        $client = static::createClient();

        $client->request('GET', '/products');

        $this->assertResponseIsSuccessful();
        $this->assertSelectorExists('.product-list');
    }

    public function testCreateProductRequiresAuth(): void
    {
        $client = static::createClient();

        $client->request('GET', '/products/new');

        $this->assertResponseRedirects('/login');
    }

    public function testCreateProductAsAdmin(): void
    {
        $client = static::createClient();

        // Create and login admin user
        $admin = $this->createAdminUser();
        $client->loginUser($admin);

        $crawler = $client->request('GET', '/products/new');

        $this->assertResponseIsSuccessful();

        // Fill and submit form
        $form = $crawler->selectButton('Create')->form([
            'product[name]' => 'New Product',
            'product[price]' => '49.99',
        ]);
        $client->submit($form);

        $this->assertResponseRedirects('/products');
        $client->followRedirect();
        $this->assertSelectorTextContains('.alert-success', 'Product created');
    }

    private function createAdminUser(): User
    {
        $user = new User();
        $user->setEmail('admin@test.com');
        $user->setRoles(['ROLE_ADMIN']);
        $user->setPassword('password');

        $entityManager = static::getContainer()->get('doctrine')->getManager();
        $entityManager->persist($user);
        $entityManager->flush();

        return $user;
    }
}
```

### API Tests

```php
namespace App\Tests\Functional\Api;

use ApiPlatform\Symfony\Bundle\Test\ApiTestCase;

final class ProductApiTest extends ApiTestCase
{
    public function testGetCollection(): void
    {
        $response = static::createClient()->request('GET', '/api/products');

        $this->assertResponseIsSuccessful();
        $this->assertResponseHeaderSame('content-type', 'application/ld+json; charset=utf-8');
        $this->assertJsonContains([
            '@context' => '/api/contexts/Product',
            '@type' => 'hydra:Collection',
        ]);
    }

    public function testCreateProduct(): void
    {
        $response = static::createClient()->request('POST', '/api/products', [
            'headers' => ['Content-Type' => 'application/ld+json'],
            'json' => [
                'name' => 'New Product',
                'price' => '99.99',
            ],
        ]);

        $this->assertResponseStatusCodeSame(201);
        $this->assertJsonContains([
            '@type' => 'Product',
            'name' => 'New Product',
            'price' => '99.99',
        ]);
    }

    public function testCreateProductValidationError(): void
    {
        static::createClient()->request('POST', '/api/products', [
            'headers' => ['Content-Type' => 'application/ld+json'],
            'json' => [
                'name' => '', // Empty name - validation error
            ],
        ]);

        $this->assertResponseStatusCodeSame(422);
        $this->assertJsonContains([
            '@type' => 'ConstraintViolationList',
        ]);
    }

    public function testUpdateProduct(): void
    {
        // First create a product
        $iri = $this->findIriBy(Product::class, ['name' => 'Existing Product']);

        static::createClient()->request('PATCH', $iri, [
            'headers' => ['Content-Type' => 'application/merge-patch+json'],
            'json' => [
                'price' => '149.99',
            ],
        ]);

        $this->assertResponseIsSuccessful();
        $this->assertJsonContains(['price' => '149.99']);
    }

    public function testDeleteProduct(): void
    {
        $iri = $this->findIriBy(Product::class, ['name' => 'Product to Delete']);

        static::createClient()->request('DELETE', $iri);

        $this->assertResponseStatusCodeSame(204);
    }
}
```

## Test Fixtures

### Using DoctrineFixturesBundle

```php
namespace App\DataFixtures;

use App\Entity\Product;
use Doctrine\Bundle\FixturesBundle\Fixture;
use Doctrine\Persistence\ObjectManager;

class ProductFixtures extends Fixture
{
    public const PRODUCT_REFERENCE = 'product-1';

    public function load(ObjectManager $manager): void
    {
        $product = new Product('Test Product', '99.99');
        $manager->persist($product);

        $this->addReference(self::PRODUCT_REFERENCE, $product);

        $manager->flush();
    }
}
```

### Loading Fixtures in Tests

```php
use Doctrine\Common\DataFixtures\Purger\ORMPurger;
use Liip\TestFixturesBundle\Services\DatabaseToolCollection;

final class ProductControllerTest extends WebTestCase
{
    private $databaseTool;

    protected function setUp(): void
    {
        parent::setUp();
        $this->databaseTool = static::getContainer()->get(DatabaseToolCollection::class)->get();
        $this->databaseTool->loadFixtures([ProductFixtures::class]);
    }
}
```

## Mocking Best Practices

### Using Prophecy (Alternative)

```php
use Prophecy\PhpUnit\ProphecyTrait;

final class OrderServiceTest extends TestCase
{
    use ProphecyTrait;

    public function testComplete(): void
    {
        $repository = $this->prophesize(OrderRepository::class);
        $notifier = $this->prophesize(NotificationService::class);

        $order = new Order();

        $repository->save($order)->shouldBeCalledOnce();
        $notifier->sendOrderConfirmation($order)->shouldBeCalledOnce();

        $service = new OrderService(
            $repository->reveal(),
            $notifier->reveal()
        );

        $service->complete($order);
    }
}
```

### Partial Mocks

```php
public function testPartialMock(): void
{
    $service = $this->getMockBuilder(ProductService::class)
        ->setConstructorArgs([$this->repository])
        ->onlyMethods(['sendNotification']) // Only mock this method
        ->getMock();

    $service->expects($this->once())
        ->method('sendNotification');

    $service->create($dto); // Other methods work normally
}
```

## Testing Commands

```php
namespace App\Tests\Command;

use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Bundle\FrameworkBundle\Test\KernelTestCase;
use Symfony\Component\Console\Tester\CommandTester;

final class ImportProductsCommandTest extends KernelTestCase
{
    public function testExecute(): void
    {
        $kernel = self::bootKernel();
        $application = new Application($kernel);

        $command = $application->find('app:import-products');
        $commandTester = new CommandTester($command);

        $commandTester->execute([
            'file' => 'tests/fixtures/products.csv',
        ]);

        $commandTester->assertCommandIsSuccessful();
        $this->assertStringContainsString('Imported 10 products', $commandTester->getDisplay());
    }

    public function testExecuteWithInvalidFile(): void
    {
        $kernel = self::bootKernel();
        $application = new Application($kernel);

        $command = $application->find('app:import-products');
        $commandTester = new CommandTester($command);

        $commandTester->execute([
            'file' => 'nonexistent.csv',
        ]);

        $this->assertSame(1, $commandTester->getStatusCode());
        $this->assertStringContainsString('File not found', $commandTester->getDisplay());
    }
}
```

## Running Tests

```bash
# Run all tests
php bin/phpunit

# Run specific test file
php bin/phpunit tests/Unit/Service/ProductServiceTest.php

# Run specific test method
php bin/phpunit --filter testCreateProduct

# Run tests in directory
php bin/phpunit tests/Unit/

# Run with coverage
php bin/phpunit --coverage-html coverage/

# Run in parallel (requires paratest)
php vendor/bin/paratest -p 4
```

## PHPUnit Configuration

```xml
<!-- phpunit.xml.dist -->
<?xml version="1.0" encoding="UTF-8"?>
<phpunit xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:noNamespaceSchemaLocation="vendor/phpunit/phpunit/phpunit.xsd"
         colors="true"
         bootstrap="tests/bootstrap.php">
    <php>
        <ini name="display_errors" value="1"/>
        <ini name="error_reporting" value="-1"/>
        <server name="APP_ENV" value="test" force="true"/>
        <server name="SHELL_VERBOSITY" value="-1"/>
    </php>

    <testsuites>
        <testsuite name="Unit">
            <directory>tests/Unit</directory>
        </testsuite>
        <testsuite name="Integration">
            <directory>tests/Integration</directory>
        </testsuite>
        <testsuite name="Functional">
            <directory>tests/Functional</directory>
        </testsuite>
    </testsuites>

    <coverage>
        <include>
            <directory suffix=".php">src</directory>
        </include>
    </coverage>
</phpunit>
```

## Best Practices

1. **Follow AAA pattern**: Arrange, Act, Assert
2. **One assertion focus**: Test one behavior per test
3. **Descriptive names**: `testCreateProductWithInvalidPrice`
4. **Independent tests**: No test should depend on another
5. **Fast tests**: Unit tests should be milliseconds
6. **Mock external services**: Don't hit real APIs
7. **Use data providers**: For testing multiple inputs
8. **Test edge cases**: Null, empty, boundary values
9. **Keep tests maintainable**: DRY with setUp and helpers
10. **Run tests before commit**: Always verify green suite
