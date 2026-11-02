"""User-scoped persistence boundaries for the Swara API.

Repositories in this package accept a request-scoped Supabase client. They do
not create or cache clients, and they never accept a service key for ordinary
user operations.
"""

from server.repositories.common import ConflictError, NotFoundError, RepositoryError

__all__ = ["ConflictError", "NotFoundError", "RepositoryError"]
