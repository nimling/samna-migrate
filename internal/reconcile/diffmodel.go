package reconcile

type Class int

const (
	Same Class = iota
	Added
	Dropped
	Changed
	Reordered
)

func (c Class) String() string {
	switch c {
	case Added:
		return "added"
	case Dropped:
		return "dropped"
	case Changed:
		return "changed"
	case Reordered:
		return "reordered"
	}
	return "same"
}

type ObjectDiff struct {
	Class        Class
	Kind         string
	Name         string
	LocalLine    int
	DeployedLine int
	Hunks        []Hunk
}

type FileDiff struct {
	FilePath       string
	Class          Class
	LocalPos       int
	DeployedPos    int
	State          string
	HasBody        bool
	WhitespaceOnly bool
	Hunks          []Hunk
	FileEdits      []Edit
	Objects        []ObjectDiff
}

type Report struct {
	Files     []FileDiff
	Added     int
	Dropped   int
	Changed   int
	Reordered int
	Same      int
	Truncated bool
}

func (r *Report) Drifted() bool {
	return r.Added+r.Dropped+r.Changed+r.Reordered > 0
}
