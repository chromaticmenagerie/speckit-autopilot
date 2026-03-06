---
document: epic
epic_id: epic-NNN
version: 1.0.0
status: draft
branch:
created: YYYY-MM-DD
project: PROJECT_NAME
---

# Epic: [Title]

**ID**: epic-NNN
**Description**: [1-2 sentence summary of what this epic delivers]

## Functional Requirements

### [Feature Area 1]

- The system shall ...
- When [condition], the system shall ...

### [Feature Area 2]

- The system shall ...

## Acceptance Criteria

### [Feature Area 1]

- [ ] [Testable assertion mapping to a functional requirement above]
- [ ] ...

### [Feature Area 2]

- [ ] ...

## Implementation Hints

1. [First step description] (depends on: [list dependencies])
2. [Second step] (depends on: 1)

## API Endpoints

| Method | Path | Description | Permissions |
|--------|------|-------------|-------------|
| GET    | `/api/v1/...` | ... | Authenticated |

## Out of Scope

- [Explicitly excluded item 1]
- [Explicitly excluded item 2]

## Dependencies

- **epic-NNN** ([Name]) — requires: [what specifically is needed from that epic]

## Self-Containment Checklist

- [ ] All functional requirements reference only tables/entities that exist or will be created in this epic
- [ ] No user story depends on tables or APIs from future (unmerged) epics
- [ ] Every acceptance criterion can be tested using only this epic's code + its merged dependencies
- [ ] The Dependencies section lists every referenced epic and its current status

## Notes

- [Context, historical references, library recommendations]

---

[<- Back to PRD](../prd.md)
