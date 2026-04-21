# API Platform Reference

Comprehensive guide for building APIs with API Platform 3.x in Symfony 7/8.

## Resource Configuration

### Basic Resource

```php
use ApiPlatform\Metadata\ApiResource;
use ApiPlatform\Metadata\Get;
use ApiPlatform\Metadata\GetCollection;
use ApiPlatform\Metadata\Post;
use ApiPlatform\Metadata\Put;
use ApiPlatform\Metadata\Patch;
use ApiPlatform\Metadata\Delete;

#[ApiResource(
    operations: [
        new GetCollection(),
        new Get(),
        new Post(),
        new Put(),
        new Patch(),
        new Delete(),
    ],
    normalizationContext: ['groups' => ['product:read']],
    denormalizationContext: ['groups' => ['product:write']],
)]
#[ORM\Entity]
class Product
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    #[Groups(['product:read'])]
    private ?int $id = null;

    #[ORM\Column(length: 255)]
    #[Groups(['product:read', 'product:write'])]
    #[Assert\NotBlank]
    #[Assert\Length(min: 3, max: 255)]
    private string $name;

    #[ORM\Column(type: Types::DECIMAL, precision: 10, scale: 2)]
    #[Groups(['product:read', 'product:write'])]
    #[Assert\Positive]
    private string $price;
}
```

### Custom Operations

```php
#[ApiResource(
    operations: [
        new GetCollection(),
        new Get(),
        new Post(),
        new Post(
            uriTemplate: '/products/{id}/publish',
            controller: PublishProductController::class,
            name: 'publish',
            openapiContext: [
                'summary' => 'Publish a product',
                'description' => 'Makes the product publicly visible',
            ],
        ),
        new GetCollection(
            uriTemplate: '/products/featured',
            controller: FeaturedProductsController::class,
            name: 'featured',
        ),
    ],
)]
class Product { }
```

### State Providers and Processors

**Custom Provider:**

```php
use ApiPlatform\Metadata\Operation;
use ApiPlatform\State\ProviderInterface;

final class ProductProvider implements ProviderInterface
{
    public function __construct(
        private readonly ProductRepository $repository,
        private readonly Security $security,
    ) {}

    public function provide(Operation $operation, array $uriVariables = [], array $context = []): object|array|null
    {
        if ($operation instanceof CollectionOperationInterface) {
            return $this->repository->findVisibleForUser($this->security->getUser());
        }

        return $this->repository->find($uriVariables['id']);
    }
}
```

**Custom Processor:**

```php
use ApiPlatform\Metadata\Operation;
use ApiPlatform\State\ProcessorInterface;

final class ProductProcessor implements ProcessorInterface
{
    public function __construct(
        private readonly ProductRepository $repository,
        private readonly EventDispatcherInterface $dispatcher,
    ) {}

    public function process(mixed $data, Operation $operation, array $uriVariables = [], array $context = []): Product
    {
        $this->repository->save($data);
        $this->dispatcher->dispatch(new ProductCreatedEvent($data));

        return $data;
    }
}
```

**Register in Resource:**

```php
#[ApiResource(
    operations: [
        new Get(provider: ProductProvider::class),
        new GetCollection(provider: ProductProvider::class),
        new Post(processor: ProductProcessor::class),
    ],
)]
class Product { }
```

## DTOs (Data Transfer Objects)

### Input DTO

```php
#[ApiResource(
    operations: [
        new Post(input: CreateProductInput::class),
    ],
)]
class Product { }

final class CreateProductInput
{
    #[Assert\NotBlank]
    #[Assert\Length(min: 3, max: 255)]
    public string $name;

    #[Assert\NotBlank]
    #[Assert\Positive]
    public string $price;

    #[Assert\NotNull]
    public int $categoryId;
}
```

### Output DTO

```php
#[ApiResource(
    operations: [
        new Get(output: ProductOutput::class),
        new GetCollection(output: ProductOutput::class),
    ],
)]
class Product { }

final readonly class ProductOutput
{
    public function __construct(
        public int $id,
        public string $name,
        public string $price,
        public string $categoryName,
        public int $reviewCount,
    ) {}
}
```

### State Provider for DTO Transformation

```php
final class ProductOutputProvider implements ProviderInterface
{
    public function __construct(
        private readonly ProductRepository $repository,
    ) {}

    public function provide(Operation $operation, array $uriVariables = [], array $context = []): ProductOutput|iterable
    {
        if ($operation instanceof CollectionOperationInterface) {
            $products = $this->repository->findAll();
            return array_map($this->transform(...), $products);
        }

        $product = $this->repository->find($uriVariables['id']);
        return $this->transform($product);
    }

    private function transform(Product $product): ProductOutput
    {
        return new ProductOutput(
            id: $product->getId(),
            name: $product->getName(),
            price: $product->getPrice(),
            categoryName: $product->getCategory()->getName(),
            reviewCount: $product->getReviews()->count(),
        );
    }
}
```

## Filters

### Built-in Filters

```php
use ApiPlatform\Doctrine\Orm\Filter\SearchFilter;
use ApiPlatform\Doctrine\Orm\Filter\OrderFilter;
use ApiPlatform\Doctrine\Orm\Filter\RangeFilter;
use ApiPlatform\Doctrine\Orm\Filter\BooleanFilter;
use ApiPlatform\Doctrine\Orm\Filter\DateFilter;

#[ApiResource]
#[ApiFilter(SearchFilter::class, properties: [
    'name' => 'partial',
    'category.name' => 'exact',
])]
#[ApiFilter(OrderFilter::class, properties: ['name', 'price', 'createdAt'])]
#[ApiFilter(RangeFilter::class, properties: ['price'])]
#[ApiFilter(BooleanFilter::class, properties: ['isActive'])]
#[ApiFilter(DateFilter::class, properties: ['createdAt'])]
class Product { }
```

### Custom Filter

```php
use ApiPlatform\Doctrine\Orm\Filter\AbstractFilter;
use ApiPlatform\Metadata\Operation;
use Doctrine\ORM\QueryBuilder;

final class FeaturedFilter extends AbstractFilter
{
    protected function filterProperty(
        string $property,
        $value,
        QueryBuilder $queryBuilder,
        QueryBuilderNameGeneratorInterface $queryNameGenerator,
        string $resourceClass,
        ?Operation $operation = null,
        array $context = [],
    ): void {
        if ($property !== 'featured') {
            return;
        }

        $alias = $queryBuilder->getRootAliases()[0];
        $queryBuilder
            ->andWhere(sprintf('%s.isFeatured = :featured', $alias))
            ->setParameter('featured', filter_var($value, FILTER_VALIDATE_BOOLEAN));
    }

    public function getDescription(string $resourceClass): array
    {
        return [
            'featured' => [
                'property' => 'featured',
                'type' => 'bool',
                'required' => false,
                'description' => 'Filter by featured status',
            ],
        ];
    }
}
```

## Pagination

```php
#[ApiResource(
    paginationEnabled: true,
    paginationItemsPerPage: 30,
    paginationMaximumItemsPerPage: 100,
    paginationClientEnabled: true,
    paginationClientItemsPerPage: true,
)]
class Product { }
```

## Subresources

```php
#[ApiResource]
class Category
{
    #[ORM\OneToMany(targetEntity: Product::class, mappedBy: 'category')]
    #[ApiProperty(readable: false)]
    private Collection $products;
}

#[ApiResource(
    uriTemplate: '/categories/{categoryId}/products',
    operations: [new GetCollection()],
    uriVariables: [
        'categoryId' => new Link(
            fromProperty: 'products',
            fromClass: Category::class,
        ),
    ],
)]
class Product { }
```

## Validation

```php
use Symfony\Component\Validator\Constraints as Assert;

#[ApiResource]
class Product
{
    #[Assert\NotBlank(message: 'Name is required')]
    #[Assert\Length(
        min: 3,
        max: 255,
        minMessage: 'Name must be at least {{ limit }} characters',
        maxMessage: 'Name cannot exceed {{ limit }} characters',
    )]
    private string $name;

    #[Assert\NotNull]
    #[Assert\Positive(message: 'Price must be positive')]
    private string $price;

    #[Assert\Valid] // Validates nested objects
    private Category $category;
}
```

## Security

```php
#[ApiResource(
    operations: [
        new GetCollection(security: "is_granted('ROLE_USER')"),
        new Get(security: "is_granted('ROLE_USER')"),
        new Post(security: "is_granted('ROLE_ADMIN')"),
        new Put(security: "is_granted('PRODUCT_EDIT', object)"),
        new Delete(security: "is_granted('ROLE_ADMIN')"),
    ],
)]
class Product { }
```

## Testing API Platform

```php
use ApiPlatform\Symfony\Bundle\Test\ApiTestCase;

final class ProductApiTest extends ApiTestCase
{
    public function testGetCollection(): void
    {
        $response = static::createClient()->request('GET', '/api/products');

        $this->assertResponseIsSuccessful();
        $this->assertJsonContains(['@context' => '/api/contexts/Product']);
    }

    public function testCreateProduct(): void
    {
        $response = static::createClient()->request('POST', '/api/products', [
            'json' => [
                'name' => 'Test Product',
                'price' => '99.99',
            ],
        ]);

        $this->assertResponseStatusCodeSame(201);
        $this->assertJsonContains([
            'name' => 'Test Product',
            'price' => '99.99',
        ]);
    }

    public function testCreateProductValidation(): void
    {
        $response = static::createClient()->request('POST', '/api/products', [
            'json' => [
                'name' => '', // Invalid: blank
            ],
        ]);

        $this->assertResponseStatusCodeSame(422);
    }
}
```
