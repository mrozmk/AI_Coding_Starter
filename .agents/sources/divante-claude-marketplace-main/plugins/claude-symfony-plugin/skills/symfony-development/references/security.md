# Symfony Security Reference

Complete guide for authentication and authorization in Symfony 7/8.

## Security Configuration

### config/packages/security.yaml

```yaml
security:
    # Password hashing
    password_hashers:
        Symfony\Component\Security\Core\User\PasswordAuthenticatedUserInterface: 'auto'

    # User providers
    providers:
        app_user_provider:
            entity:
                class: App\Entity\User
                property: email

    # Firewalls
    firewalls:
        dev:
            pattern: ^/(_(profiler|wdt)|css|images|js)/
            security: false

        api:
            pattern: ^/api
            stateless: true
            jwt: ~
            # Or custom authenticator:
            # custom_authenticators:
            #     - App\Security\ApiTokenAuthenticator

        main:
            lazy: true
            provider: app_user_provider
            form_login:
                login_path: app_login
                check_path: app_login
                default_target_path: app_dashboard
                enable_csrf: true
            logout:
                path: app_logout
                target: app_home
            remember_me:
                secret: '%kernel.secret%'
                lifetime: 604800 # 1 week

    # Access control rules
    access_control:
        - { path: ^/admin, roles: ROLE_ADMIN }
        - { path: ^/api/public, roles: PUBLIC_ACCESS }
        - { path: ^/api, roles: ROLE_USER }
        - { path: ^/profile, roles: ROLE_USER }

    # Role hierarchy
    role_hierarchy:
        ROLE_ADMIN: [ROLE_USER, ROLE_MODERATOR]
        ROLE_SUPER_ADMIN: [ROLE_ADMIN, ROLE_ALLOWED_TO_SWITCH]
```

## User Entity

```php
namespace App\Entity;

use Doctrine\ORM\Mapping as ORM;
use Symfony\Component\Security\Core\User\PasswordAuthenticatedUserInterface;
use Symfony\Component\Security\Core\User\UserInterface;

#[ORM\Entity(repositoryClass: UserRepository::class)]
#[ORM\Table(name: 'users')]
#[UniqueEntity(fields: ['email'], message: 'This email is already registered')]
class User implements UserInterface, PasswordAuthenticatedUserInterface
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    private ?int $id = null;

    #[ORM\Column(length: 180, unique: true)]
    private string $email;

    #[ORM\Column]
    private array $roles = [];

    #[ORM\Column]
    private string $password;

    #[ORM\Column(length: 255)]
    private string $name;

    #[ORM\Column]
    private bool $isVerified = false;

    public function getId(): ?int
    {
        return $this->id;
    }

    public function getEmail(): string
    {
        return $this->email;
    }

    public function setEmail(string $email): static
    {
        $this->email = $email;
        return $this;
    }

    public function getUserIdentifier(): string
    {
        return $this->email;
    }

    public function getRoles(): array
    {
        $roles = $this->roles;
        $roles[] = 'ROLE_USER'; // Guarantee every user has ROLE_USER

        return array_unique($roles);
    }

    public function setRoles(array $roles): static
    {
        $this->roles = $roles;
        return $this;
    }

    public function getPassword(): string
    {
        return $this->password;
    }

    public function setPassword(string $password): static
    {
        $this->password = $password;
        return $this;
    }

    public function eraseCredentials(): void
    {
        // Clear temporary sensitive data
    }
}
```

## Voters

### Basic Voter

```php
namespace App\Security\Voter;

use App\Entity\Post;
use App\Entity\User;
use Symfony\Component\Security\Core\Authentication\Token\TokenInterface;
use Symfony\Component\Security\Core\Authorization\Voter\Voter;

final class PostVoter extends Voter
{
    public const VIEW = 'POST_VIEW';
    public const EDIT = 'POST_EDIT';
    public const DELETE = 'POST_DELETE';

    protected function supports(string $attribute, mixed $subject): bool
    {
        return in_array($attribute, [self::VIEW, self::EDIT, self::DELETE])
            && $subject instanceof Post;
    }

    protected function voteOnAttribute(string $attribute, mixed $subject, TokenInterface $token): bool
    {
        $user = $token->getUser();

        // Allow public viewing
        if ($attribute === self::VIEW && $subject->isPublished()) {
            return true;
        }

        // User must be logged in for other actions
        if (!$user instanceof User) {
            return false;
        }

        /** @var Post $post */
        $post = $subject;

        return match ($attribute) {
            self::VIEW => $this->canView($post, $user),
            self::EDIT => $this->canEdit($post, $user),
            self::DELETE => $this->canDelete($post, $user),
            default => false,
        };
    }

    private function canView(Post $post, User $user): bool
    {
        // Author can always view their own posts
        return $post->getAuthor() === $user;
    }

    private function canEdit(Post $post, User $user): bool
    {
        // Only author can edit
        return $post->getAuthor() === $user;
    }

    private function canDelete(Post $post, User $user): bool
    {
        // Author or admin can delete
        return $post->getAuthor() === $user
            || in_array('ROLE_ADMIN', $user->getRoles());
    }
}
```

### Using Voters in Controllers

```php
#[Route('/posts/{id}/edit', name: 'post_edit')]
public function edit(Post $post): Response
{
    $this->denyAccessUnlessGranted(PostVoter::EDIT, $post);

    // User can edit...
}

// Or with attribute
#[Route('/posts/{id}/edit', name: 'post_edit')]
#[IsGranted(PostVoter::EDIT, subject: 'post')]
public function edit(Post $post): Response
{
    // User can edit...
}
```

### Using Voters in Templates

```twig
{% if is_granted('POST_EDIT', post) %}
    <a href="{{ path('post_edit', {id: post.id}) }}">Edit</a>
{% endif %}
```

## Custom Authenticators

### API Token Authenticator

```php
namespace App\Security;

use App\Repository\ApiTokenRepository;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Security\Core\Authentication\Token\TokenInterface;
use Symfony\Component\Security\Core\Exception\AuthenticationException;
use Symfony\Component\Security\Core\Exception\CustomUserMessageAuthenticationException;
use Symfony\Component\Security\Http\Authenticator\AbstractAuthenticator;
use Symfony\Component\Security\Http\Authenticator\Passport\Badge\UserBadge;
use Symfony\Component\Security\Http\Authenticator\Passport\Passport;
use Symfony\Component\Security\Http\Authenticator\Passport\SelfValidatingPassport;

final class ApiTokenAuthenticator extends AbstractAuthenticator
{
    public function __construct(
        private readonly ApiTokenRepository $tokenRepository,
    ) {}

    public function supports(Request $request): ?bool
    {
        return $request->headers->has('Authorization')
            && str_starts_with($request->headers->get('Authorization'), 'Bearer ');
    }

    public function authenticate(Request $request): Passport
    {
        $authHeader = $request->headers->get('Authorization');
        $token = substr($authHeader, 7); // Remove "Bearer "

        if (empty($token)) {
            throw new CustomUserMessageAuthenticationException('No API token provided');
        }

        $apiToken = $this->tokenRepository->findOneBy(['token' => $token]);

        if (!$apiToken || $apiToken->isExpired()) {
            throw new CustomUserMessageAuthenticationException('Invalid or expired API token');
        }

        return new SelfValidatingPassport(
            new UserBadge($apiToken->getUser()->getUserIdentifier())
        );
    }

    public function onAuthenticationSuccess(Request $request, TokenInterface $token, string $firewallName): ?Response
    {
        // Continue with request
        return null;
    }

    public function onAuthenticationFailure(Request $request, AuthenticationException $exception): ?Response
    {
        return new JsonResponse([
            'error' => $exception->getMessageKey(),
        ], Response::HTTP_UNAUTHORIZED);
    }
}
```

## JWT Authentication (LexikJWTAuthenticationBundle)

### Installation

```bash
composer require lexik/jwt-authentication-bundle
```

### Configuration

```yaml
# config/packages/lexik_jwt_authentication.yaml
lexik_jwt_authentication:
    secret_key: '%env(resolve:JWT_SECRET_KEY)%'
    public_key: '%env(resolve:JWT_PUBLIC_KEY)%'
    pass_phrase: '%env(JWT_PASSPHRASE)%'
    token_ttl: 3600 # 1 hour
```

### Generate Keys

```bash
php bin/console lexik:jwt:generate-keypair
```

### Login Endpoint

```php
namespace App\Controller;

use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Attribute\Route;

class AuthController extends AbstractController
{
    #[Route('/api/login', name: 'api_login', methods: ['POST'])]
    public function login(): JsonResponse
    {
        // This method is intercepted by the JWT authenticator
        // The user is already authenticated when we get here
        $user = $this->getUser();

        return $this->json([
            'user' => $user->getUserIdentifier(),
            'roles' => $user->getRoles(),
        ]);
    }
}
```

## Password Hashing

```php
use Symfony\Component\PasswordHasher\Hasher\UserPasswordHasherInterface;

final class UserService
{
    public function __construct(
        private readonly UserPasswordHasherInterface $passwordHasher,
        private readonly UserRepository $repository,
    ) {}

    public function register(RegistrationDTO $dto): User
    {
        $user = new User();
        $user->setEmail($dto->email);
        $user->setName($dto->name);

        // Hash the password
        $hashedPassword = $this->passwordHasher->hashPassword(
            $user,
            $dto->plainPassword
        );
        $user->setPassword($hashedPassword);

        $this->repository->save($user);

        return $user;
    }

    public function changePassword(User $user, string $newPassword): void
    {
        $hashedPassword = $this->passwordHasher->hashPassword($user, $newPassword);
        $user->setPassword($hashedPassword);
        $this->repository->save($user);
    }
}
```

## Access Control in Services

```php
use Symfony\Bundle\SecurityBundle\Security;

final class DocumentService
{
    public function __construct(
        private readonly Security $security,
        private readonly DocumentRepository $repository,
    ) {}

    public function getDocument(int $id): Document
    {
        $document = $this->repository->find($id);

        if (!$this->security->isGranted('DOCUMENT_VIEW', $document)) {
            throw new AccessDeniedException('You cannot view this document.');
        }

        return $document;
    }

    public function deleteDocument(Document $document): void
    {
        // Check if user is admin
        if (!$this->security->isGranted('ROLE_ADMIN')) {
            throw new AccessDeniedException('Only admins can delete documents.');
        }

        $this->repository->remove($document);
    }

    public function getCurrentUser(): ?User
    {
        return $this->security->getUser();
    }
}
```

## Testing Security

### Testing Voters

```php
final class PostVoterTest extends TestCase
{
    private PostVoter $voter;

    protected function setUp(): void
    {
        $this->voter = new PostVoter();
    }

    public function testAuthorCanEdit(): void
    {
        $user = new User();
        $post = new Post();
        $post->setAuthor($user);

        $token = $this->createMock(TokenInterface::class);
        $token->method('getUser')->willReturn($user);

        $result = $this->voter->vote($token, $post, [PostVoter::EDIT]);

        $this->assertSame(VoterInterface::ACCESS_GRANTED, $result);
    }

    public function testNonAuthorCannotEdit(): void
    {
        $author = new User();
        $otherUser = new User();
        $post = new Post();
        $post->setAuthor($author);

        $token = $this->createMock(TokenInterface::class);
        $token->method('getUser')->willReturn($otherUser);

        $result = $this->voter->vote($token, $post, [PostVoter::EDIT]);

        $this->assertSame(VoterInterface::ACCESS_DENIED, $result);
    }
}
```

### Testing Protected Endpoints

```php
final class AdminControllerTest extends WebTestCase
{
    public function testAdminPageRequiresAdminRole(): void
    {
        $client = static::createClient();

        // Login as regular user
        $user = $this->createUser(['ROLE_USER']);
        $client->loginUser($user);

        $client->request('GET', '/admin');

        $this->assertResponseStatusCodeSame(403);
    }

    public function testAdminCanAccessAdminPage(): void
    {
        $client = static::createClient();

        // Login as admin
        $admin = $this->createUser(['ROLE_ADMIN']);
        $client->loginUser($admin);

        $client->request('GET', '/admin');

        $this->assertResponseIsSuccessful();
    }

    private function createUser(array $roles): User
    {
        $user = new User();
        $user->setEmail('test@example.com');
        $user->setRoles($roles);
        $user->setPassword('password');

        return $user;
    }
}
```

## Best Practices

1. **Always use voters** for object-level authorization
2. **Keep firewalls simple** - one firewall per authentication mechanism
3. **Use role hierarchy** for related roles
4. **Hash passwords properly** - use auto hasher
5. **Stateless for APIs** - JWT or API tokens
6. **Test security thoroughly** - voters, authenticators, access control
7. **Never expose sensitive data** - use serialization groups
8. **Enable CSRF** for form-based authentication
