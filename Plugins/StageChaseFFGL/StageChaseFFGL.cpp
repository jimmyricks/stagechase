#include <FFGLEffect.h>
#include <FFGLParamOption.h>
#include <FFGLParamRange.h>
#include <FFGLScopedSamplerActivation.h>
#include <FFGLScopedTextureBinding.h>
#include <FFGLUtilities.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

using namespace ffglex;
using namespace ffglqs;

namespace
{
struct Point
{
	float x;
	float y;
};

struct Slice
{
	std::vector< Point > points;
	std::vector< size_t > triangles;
};

struct Step
{
	std::vector< size_t > slices;
};

struct Sequence
{
	std::vector< Step > steps;
	int echoes = 0;
};

struct Project
{
	double canvasWidth = 1.0;
	double canvasHeight = 1.0;
	std::vector< Slice > slices;
	std::vector< Sequence > sequences;
};

struct MaskVertex
{
	float x;
	float y;
	float z;
	float u;
	float v;
};

static float Cross( const Point& a, const Point& b, const Point& c )
{
	return ( b.x - a.x ) * ( c.y - a.y ) - ( b.y - a.y ) * ( c.x - a.x );
}

static bool PointInTriangle( const Point& point, const Point& a, const Point& b, const Point& c, float orientation )
{
	constexpr float epsilon = 0.000001f;
	return Cross( a, b, point ) * orientation >= -epsilon &&
		Cross( b, c, point ) * orientation >= -epsilon &&
		Cross( c, a, point ) * orientation >= -epsilon;
}

static std::vector< size_t > Triangulate( const std::vector< Point >& points )
{
	if( points.size() < 3 )
		return {};

	float area = 0.0f;
	for( size_t index = 0; index < points.size(); ++index )
	{
		const Point& current = points[ index ];
		const Point& next = points[ ( index + 1 ) % points.size() ];
		area += current.x * next.y - next.x * current.y;
	}
	const float orientation = area >= 0.0f ? 1.0f : -1.0f;

	std::vector< size_t > remaining( points.size() );
	std::iota( remaining.begin(), remaining.end(), 0 );
	std::vector< size_t > triangles;
	triangles.reserve( ( points.size() - 2 ) * 3 );

	while( remaining.size() > 3 )
	{
		bool clippedEar = false;
		for( size_t index = 0; index < remaining.size(); ++index )
		{
			const size_t previous = remaining[ ( index + remaining.size() - 1 ) % remaining.size() ];
			const size_t current = remaining[ index ];
			const size_t next = remaining[ ( index + 1 ) % remaining.size() ];
			if( Cross( points[ previous ], points[ current ], points[ next ] ) * orientation <= 0.000001f )
				continue;

			bool containsVertex = false;
			for( size_t candidate : remaining )
			{
				if( candidate == previous || candidate == current || candidate == next )
					continue;
				if( PointInTriangle( points[ candidate ], points[ previous ], points[ current ], points[ next ], orientation ) )
				{
					containsVertex = true;
					break;
				}
			}
			if( containsVertex )
				continue;

			triangles.insert( triangles.end(), { previous, current, next } );
			remaining.erase( remaining.begin() + static_cast< std::ptrdiff_t >( index ) );
			clippedEar = true;
			break;
		}
		if( !clippedEar )
			return {};
	}

	triangles.insert( triangles.end(), remaining.begin(), remaining.end() );
	return triangles;
}

static std::filesystem::path SnapshotPath()
{
	const char* home = std::getenv( "HOME" );
	if( home == nullptr )
		return {};
	return std::filesystem::path( home ) / "Library/Application Support/StageChase/LiveProject.stagechase-live";
}

static bool ReadProject( const std::filesystem::path& path, Project& project )
{
	std::ifstream stream( path );
	std::string magic;
	int version = 0;
	if( !( stream >> magic >> version ) || magic != "STAGECHASE" || version != 1 )
		return false;

	Project loaded;
	size_t sliceCount = 0;
	if( !( stream >> loaded.canvasWidth >> loaded.canvasHeight >> sliceCount ) ||
		sliceCount > 10000 || loaded.canvasWidth <= 0 || loaded.canvasHeight <= 0 )
		return false;

	loaded.slices.reserve( sliceCount );
	for( size_t index = 0; index < sliceCount; ++index )
	{
		size_t pointCount = 0;
		if( !( stream >> pointCount ) || pointCount < 3 || pointCount > 4096 )
			return false;
		Slice slice;
		slice.points.reserve( pointCount );
		for( size_t point = 0; point < pointCount; ++point )
		{
			Point value{};
			if( !( stream >> value.x >> value.y ) ||
				!std::isfinite( value.x ) || !std::isfinite( value.y ) )
				return false;
			slice.points.push_back( value );
		}
		slice.triangles = Triangulate( slice.points );
		if( slice.triangles.empty() )
			return false;
		loaded.slices.push_back( std::move( slice ) );
	}

	size_t sequenceCount = 0;
	if( !( stream >> sequenceCount ) || sequenceCount == 0 || sequenceCount > 1024 )
		return false;
	loaded.sequences.reserve( sequenceCount );
	for( size_t sequenceIndex = 0; sequenceIndex < sequenceCount; ++sequenceIndex )
	{
		size_t stepCount = 0;
		std::string direction;
		std::string scaling;
		double stepDuration = 0;
		Sequence sequence;
		if( !( stream >> stepCount >> direction >> stepDuration >> scaling >> sequence.echoes ) ||
			stepCount == 0 || stepCount > 1024 || sequence.echoes < 0 || sequence.echoes > 32 )
			return false;
		sequence.steps.reserve( stepCount );
		for( size_t stepIndex = 0; stepIndex < stepCount; ++stepIndex )
		{
			size_t activeCount = 0;
			if( !( stream >> activeCount ) || activeCount > sliceCount )
				return false;
			Step step;
			step.slices.reserve( activeCount );
			for( size_t activeIndex = 0; activeIndex < activeCount; ++activeIndex )
			{
				size_t sliceIndex = 0;
				if( !( stream >> sliceIndex ) || sliceIndex >= sliceCount )
					return false;
				step.slices.push_back( sliceIndex );
			}
			sequence.steps.push_back( std::move( step ) );
		}
		loaded.sequences.push_back( std::move( sequence ) );
	}

	project = std::move( loaded );
	return true;
}

static GLuint CreateMaskProgram()
{
	const char* vertexSource = R"(
		#version 150
		in vec3 position;
		in vec2 sourceUV;
		out vec2 uv;
		void main()
		{
			gl_Position = vec4( position, 1.0 );
			uv = sourceUV;
		}
	)";
	const char* fragmentSource = R"(
		#version 150
		in vec2 uv;
		out vec4 fragColor;
		void main()
		{
			fragColor = vec4( uv, 1.0, 1.0 );
		}
	)";

	auto compile = []( GLenum type, const char* source ) -> GLuint {
		const GLuint shader = glCreateShader( type );
		glShaderSource( shader, 1, &source, nullptr );
		glCompileShader( shader );
		GLint compiled = GL_FALSE;
		glGetShaderiv( shader, GL_COMPILE_STATUS, &compiled );
		if( compiled == GL_TRUE )
			return shader;
		glDeleteShader( shader );
		return 0;
	};

	const GLuint vertexShader = compile( GL_VERTEX_SHADER, vertexSource );
	const GLuint fragmentShader = compile( GL_FRAGMENT_SHADER, fragmentSource );
	if( vertexShader == 0 || fragmentShader == 0 )
	{
		if( vertexShader != 0 ) glDeleteShader( vertexShader );
		if( fragmentShader != 0 ) glDeleteShader( fragmentShader );
		return 0;
	}

	const GLuint program = glCreateProgram();
	glAttachShader( program, vertexShader );
	glAttachShader( program, fragmentShader );
	glBindAttribLocation( program, 0, "position" );
	glBindAttribLocation( program, 1, "sourceUV" );
	glLinkProgram( program );
	glDeleteShader( vertexShader );
	glDeleteShader( fragmentShader );
	GLint linked = GL_FALSE;
	glGetProgramiv( program, GL_LINK_STATUS, &linked );
	if( linked == GL_TRUE )
		return program;
	glDeleteProgram( program );
	return 0;
}

enum Parameters
{
	SequenceParameter,
	StepParameter,
	ScalingParameter,
	EchoesParameter
};

class StageChaseEffect final : public Effect
{
public:
	StageChaseEffect() :
		maskTexture( 0 ),
		maskFramebuffer( 0 ),
		maskDepthBuffer( 0 ),
		maskProgram( 0 ),
		maskVertexArray( 0 ),
		maskVertexBuffer( 0 ),
		maskWidth( 0 ),
		maskHeight( 0 ),
		lastSequence( -1 ),
		lastStepIndex( -1 ),
		lastScaling( -1 ),
		lastEchoes( -1 )
	{
		AddParam( ParamRange::CreateInteger( "Sequence", 0, { 0.0f, 1023.0f } ) );
		AddParam( ParamRange::Create( "Step", 0.0f, { 0.0f, 1.0f } ) );
		AddParam( ParamOption::Create( "Scaling", {
			{ "Fill", 0.0f },
			{ "Mask", 1.0f },
		{ "Stretch", 2.0f }
		} ) );
		AddParam( ParamRange::CreateInteger( "Echoes", 0, { 0.0f, 32.0f } ) );
		SetFragmentShader( R"(
			uniform sampler2D stageMask;
			uniform vec2 maxUV;

			void main()
			{
				vec4 mask = texture( stageMask, gl_FragCoord.xy / resolution );
				vec4 color = texture( inputTexture, mask.rg * maxUV );
				float visible = mask.b;
				fragColor = vec4( color.rgb * visible, color.a * visible );
			}
		)" );
	}

	~StageChaseEffect() override
	{
	}

	FFResult Init() override
	{
		glGenTextures( 1, &maskTexture );
		Scoped2DTextureBinding texture( maskTexture );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
		glGenFramebuffers( 1, &maskFramebuffer );
		glGenRenderbuffers( 1, &maskDepthBuffer );
		maskProgram = CreateMaskProgram();
		glGenVertexArrays( 1, &maskVertexArray );
		glGenBuffers( 1, &maskVertexBuffer );
		glBindVertexArray( maskVertexArray );
		glBindBuffer( GL_ARRAY_BUFFER, maskVertexBuffer );
		glEnableVertexAttribArray( 0 );
		glVertexAttribPointer( 0, 3, GL_FLOAT, GL_FALSE, sizeof( MaskVertex ),
			reinterpret_cast< const void* >( offsetof( MaskVertex, x ) ) );
		glEnableVertexAttribArray( 1 );
		glVertexAttribPointer( 1, 2, GL_FLOAT, GL_FALSE, sizeof( MaskVertex ),
			reinterpret_cast< const void* >( offsetof( MaskVertex, u ) ) );
		glBindVertexArray( 0 );
		stopSnapshotThread = false;
		snapshotThread = std::thread( [ this ] { SnapshotLoop(); } );
		return maskTexture == 0 || maskFramebuffer == 0 || maskDepthBuffer == 0 ||
			maskProgram == 0 || maskVertexArray == 0 || maskVertexBuffer == 0
			? FF_FAIL : FF_SUCCESS;
	}

	void Clean() override
	{
		stopSnapshotThread = true;
		if( snapshotThread.joinable() )
			snapshotThread.join();
		if( maskVertexBuffer != 0 ) glDeleteBuffers( 1, &maskVertexBuffer );
		if( maskVertexArray != 0 ) glDeleteVertexArrays( 1, &maskVertexArray );
		if( maskProgram != 0 ) glDeleteProgram( maskProgram );
		if( maskDepthBuffer != 0 ) glDeleteRenderbuffers( 1, &maskDepthBuffer );
		if( maskFramebuffer != 0 ) glDeleteFramebuffers( 1, &maskFramebuffer );
		if( maskTexture != 0 )
			glDeleteTextures( 1, &maskTexture );
		maskTexture = 0;
		maskFramebuffer = 0;
		maskDepthBuffer = 0;
		maskProgram = 0;
		maskVertexArray = 0;
		maskVertexBuffer = 0;
	}

	FFResult Render( ProcessOpenGLStruct* input ) override
	{
		if( input == nullptr || input->numInputTextures < 1 || input->inputTextures[ 0 ] == nullptr )
			return FF_FAIL;

		ApplyPendingSnapshot();
		const int width = static_cast< int >( currentViewport.width );
		const int height = static_cast< int >( currentViewport.height );
		const int sequenceIndex = std::clamp( static_cast< int >( GetFloatParameter( SequenceParameter ) ), 0, 1023 );
		const float stepValue = std::clamp( GetFloatParameter( StepParameter ), 0.0f, 1.0f );
		const int scaling = static_cast< int >( GetParamOption( "Scaling" )->GetRealValue() );
		const int echoes = std::clamp( static_cast< int >( GetFloatParameter( EchoesParameter ) ), 0, 32 );
		if( width <= 0 || height <= 0 )
			return FF_FAIL;

		// Step selects a discrete frame; BPM Sync otherwise changes this float every render.
		size_t stepIndex = 0;
		if( sequenceIndex < static_cast< int >( project.sequences.size() ) )
		{
			const size_t stepCount = project.sequences[ sequenceIndex ].steps.size();
			if( stepCount > 1 )
				stepIndex = static_cast< size_t >( std::round( stepValue * ( stepCount - 1 ) ) );
		}

		const bool resolutionChanged = width != maskWidth || height != maskHeight;
		if( resolutionChanged )
		{
			if( !EnsureMaskStorage( width, height ) )
				return FF_FAIL;
			maskWidth = width;
			maskHeight = height;
		}

		const bool selectionChanged = sequenceIndex != lastSequence || static_cast< int >( stepIndex ) != lastStepIndex ||
			scaling != lastScaling || echoes != lastEchoes || resolutionChanged;
		if( selectionChanged )
		{
			BuildMask( sequenceIndex, stepIndex, scaling, echoes );
			lastSequence = sequenceIndex;
			lastStepIndex = static_cast< int >( stepIndex );
			lastScaling = scaling;
			lastEchoes = echoes;
		}

		ScopedSamplerActivation activateInput( 0 );
		Scoped2DTextureBinding inputTexture( input->inputTextures[ 0 ]->Handle );
		ScopedSamplerActivation activateMask( 1 );
		Scoped2DTextureBinding stageMask( maskTexture );
		shader.Set( "inputTexture", 0 );
		shader.Set( "stageMask", 1 );
		const FFGLTexCoords maxUV = GetMaxGLTexCoords( *input->inputTextures[ 0 ] );
		shader.Set( "maxUV", maxUV.s, maxUV.t );
		quad.Draw();
		return FF_SUCCESS;
	}

private:
	bool EnsureMaskStorage( int width, int height )
	{
		GLint previousDrawFramebuffer = 0;
		GLint previousRenderbuffer = 0;
		glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &previousDrawFramebuffer );
		glGetIntegerv( GL_RENDERBUFFER_BINDING, &previousRenderbuffer );

		{
			Scoped2DTextureBinding texture( maskTexture );
			glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA32F, width, height, 0, GL_RGBA, GL_FLOAT, nullptr );
		}
		glBindRenderbuffer( GL_RENDERBUFFER, maskDepthBuffer );
		glRenderbufferStorage( GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height );
		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, maskFramebuffer );
		glFramebufferTexture2D( GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, maskTexture, 0 );
		glFramebufferRenderbuffer( GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, maskDepthBuffer );
		const bool complete = glCheckFramebufferStatus( GL_DRAW_FRAMEBUFFER ) == GL_FRAMEBUFFER_COMPLETE;

		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, static_cast< GLuint >( previousDrawFramebuffer ) );
		glBindRenderbuffer( GL_RENDERBUFFER, static_cast< GLuint >( previousRenderbuffer ) );
		return complete;
	}

	void SnapshotLoop()
	{
		const std::filesystem::path path = SnapshotPath();
		while( !stopSnapshotThread )
		{
			if( !path.empty() )
			{
				std::error_code error;
				const auto modified = std::filesystem::last_write_time( path, error );
				if( !error && modified != lastObservedModification )
				{
					lastObservedModification = modified;
					Project loaded;
					if( ReadProject( path, loaded ) )
					{
						std::lock_guard< std::mutex > lock( snapshotMutex );
						pendingProject = std::move( loaded );
						hasPendingProject = true;
					}
				}
			}
			std::this_thread::sleep_for( std::chrono::milliseconds( 200 ) );
		}
	}

	void ApplyPendingSnapshot()
	{
		std::lock_guard< std::mutex > lock( snapshotMutex );
		if( !hasPendingProject )
			return;
		project = std::move( pendingProject );
		hasPendingProject = false;
		lastSequence = -1;
		lastStepIndex = -1;
	}

	void BuildMask( int sequenceIndex, size_t stepIndex, int scaling, int echoes )
	{
		const Sequence* sequence = project.sequences.empty()
			? nullptr
			: &project.sequences[ std::min( static_cast< size_t >( sequenceIndex ), project.sequences.size() - 1 ) ];
		if( sequence == nullptr || sequence->steps.empty() )
			stepIndex = 0;
		else
			stepIndex = std::min( stepIndex, sequence->steps.size() - 1 );

		activeSlices.clear();
		seenSlices.assign( project.slices.size(), false );
		auto appendSlices = [ this ]( const std::vector< size_t >& slices ) {
			for( size_t sliceIndex : slices )
			{
				if( sliceIndex >= seenSlices.size() || seenSlices[ sliceIndex ] )
					continue;
				seenSlices[ sliceIndex ] = true;
				activeSlices.push_back( sliceIndex );
			}
		};

		if( sequence != nullptr && !sequence->steps.empty() )
		{
			appendSlices( sequence->steps[ stepIndex ].slices );
			const int echoCount = std::min( echoes > 0 ? echoes : sequence->echoes,
				static_cast< int >( sequence->steps.size() - 1 ) );
			for( int echo = 1; echo <= echoCount; ++echo )
			{
				const size_t previous = ( stepIndex + sequence->steps.size() - echo ) % sequence->steps.size();
				appendSlices( sequence->steps[ previous ].slices );
			}
		}

		maskVertices.clear();
		const int width = maskWidth;
		const int height = maskHeight;
		const float sourceAspect = static_cast< float >( currentViewport.width ) /
			std::max( static_cast< float >( currentViewport.height ), 1.0f );
		for( size_t order = 0; order < activeSlices.size(); ++order )
		{
			const size_t sliceIndex = activeSlices[ order ];
			if( sliceIndex >= project.slices.size() )
				continue;
			const Slice& slice = project.slices[ sliceIndex ];
			float minX = 1.0f, maxX = 0.0f, minY = 1.0f, maxY = 0.0f;
			for( const Point& point : slice.points )
			{
				minX = std::min( minX, point.x );
				maxX = std::max( maxX, point.x );
				minY = std::min( minY, point.y );
				maxY = std::max( maxY, point.y );
			}
			const float boxWidth = std::max( maxX - minX, 0.000001f );
			const float boxHeight = std::max( maxY - minY, 0.000001f );
			const float targetAspect = boxWidth * static_cast< float >( project.canvasWidth ) /
				( boxHeight * static_cast< float >( project.canvasHeight ) );
			const float depth = activeSlices.empty()
				? 0.0f
				: 0.9f * static_cast< float >( order ) / static_cast< float >( activeSlices.size() );

			for( size_t vertexIndex : slice.triangles )
			{
				const Point& point = slice.points[ vertexIndex ];
				float sourceU = point.x;
				float sourceV = 1.0f - point.y;
				if( scaling != 1 )
				{
					sourceU = ( point.x - minX ) / boxWidth;
					float sourceTop = ( point.y - minY ) / boxHeight;
					if( scaling == 0 && targetAspect > 0.0f )
					{
						if( sourceAspect > targetAspect )
							sourceU = 0.5f + ( sourceU - 0.5f ) * targetAspect / sourceAspect;
						else
							sourceTop = 0.5f + ( sourceTop - 0.5f ) * sourceAspect / targetAspect;
					}
					sourceV = 1.0f - sourceTop;
				}
				maskVertices.push_back( {
					point.x * 2.0f - 1.0f,
					1.0f - point.y * 2.0f,
					depth,
					std::clamp( sourceU, 0.0f, 1.0f ),
					std::clamp( sourceV, 0.0f, 1.0f )
				} );
			}
		}

		GLint previousDrawFramebuffer = 0;
		GLint previousViewport[ 4 ]{};
		GLint previousProgram = 0;
		GLint previousVertexArray = 0;
		GLint previousArrayBuffer = 0;
		GLint previousDepthFunction = GL_LESS;
		GLboolean previousDepthMask = GL_TRUE;
		GLboolean previousColorMask[ 4 ]{};
		GLfloat previousClearColor[ 4 ]{};
		GLdouble previousClearDepth = 1.0;
		glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &previousDrawFramebuffer );
		glGetIntegerv( GL_VIEWPORT, previousViewport );
		glGetIntegerv( GL_CURRENT_PROGRAM, &previousProgram );
		glGetIntegerv( GL_VERTEX_ARRAY_BINDING, &previousVertexArray );
		glGetIntegerv( GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer );
		glGetIntegerv( GL_DEPTH_FUNC, &previousDepthFunction );
		glGetBooleanv( GL_DEPTH_WRITEMASK, &previousDepthMask );
		glGetBooleanv( GL_COLOR_WRITEMASK, previousColorMask );
		glGetFloatv( GL_COLOR_CLEAR_VALUE, previousClearColor );
		glGetDoublev( GL_DEPTH_CLEAR_VALUE, &previousClearDepth );
		const bool depthWasEnabled = glIsEnabled( GL_DEPTH_TEST ) == GL_TRUE;
		const bool blendWasEnabled = glIsEnabled( GL_BLEND ) == GL_TRUE;
		const bool scissorWasEnabled = glIsEnabled( GL_SCISSOR_TEST ) == GL_TRUE;
		const bool cullWasEnabled = glIsEnabled( GL_CULL_FACE ) == GL_TRUE;
		const bool stencilWasEnabled = glIsEnabled( GL_STENCIL_TEST ) == GL_TRUE;

		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, maskFramebuffer );
		glViewport( 0, 0, width, height );
		glDisable( GL_BLEND );
		glDisable( GL_SCISSOR_TEST );
		glDisable( GL_CULL_FACE );
		glDisable( GL_STENCIL_TEST );
		glEnable( GL_DEPTH_TEST );
		glDepthFunc( GL_LESS );
		glDepthMask( GL_TRUE );
		glColorMask( GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE );
		glClearColor( 0.0f, 0.0f, 0.0f, 0.0f );
		glClearDepth( 1.0 );
		glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );

		if( !maskVertices.empty() )
		{
			glUseProgram( maskProgram );
			glBindVertexArray( maskVertexArray );
			glBindBuffer( GL_ARRAY_BUFFER, maskVertexBuffer );
			glBufferData( GL_ARRAY_BUFFER, maskVertices.size() * sizeof( MaskVertex ),
				maskVertices.data(), GL_STREAM_DRAW );
			glDrawArrays( GL_TRIANGLES, 0, static_cast< GLsizei >( maskVertices.size() ) );
		}

		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, static_cast< GLuint >( previousDrawFramebuffer ) );
		glViewport( previousViewport[ 0 ], previousViewport[ 1 ], previousViewport[ 2 ], previousViewport[ 3 ] );
		glUseProgram( static_cast< GLuint >( previousProgram ) );
		glBindVertexArray( static_cast< GLuint >( previousVertexArray ) );
		glBindBuffer( GL_ARRAY_BUFFER, static_cast< GLuint >( previousArrayBuffer ) );
		glDepthFunc( static_cast< GLenum >( previousDepthFunction ) );
		glDepthMask( previousDepthMask );
		glColorMask( previousColorMask[ 0 ], previousColorMask[ 1 ], previousColorMask[ 2 ], previousColorMask[ 3 ] );
		glClearColor( previousClearColor[ 0 ], previousClearColor[ 1 ], previousClearColor[ 2 ], previousClearColor[ 3 ] );
		glClearDepth( previousClearDepth );
		if( depthWasEnabled ) glEnable( GL_DEPTH_TEST ); else glDisable( GL_DEPTH_TEST );
		if( blendWasEnabled ) glEnable( GL_BLEND ); else glDisable( GL_BLEND );
		if( scissorWasEnabled ) glEnable( GL_SCISSOR_TEST ); else glDisable( GL_SCISSOR_TEST );
		if( cullWasEnabled ) glEnable( GL_CULL_FACE ); else glDisable( GL_CULL_FACE );
		if( stencilWasEnabled ) glEnable( GL_STENCIL_TEST ); else glDisable( GL_STENCIL_TEST );
	}

	GLuint maskTexture;
	GLuint maskFramebuffer;
	GLuint maskDepthBuffer;
	GLuint maskProgram;
	GLuint maskVertexArray;
	GLuint maskVertexBuffer;
	int maskWidth;
	int maskHeight;
	int lastSequence;
	int lastStepIndex;
	int lastScaling;
	int lastEchoes;
	std::vector< size_t > activeSlices;
	std::vector< bool > seenSlices;
	std::vector< MaskVertex > maskVertices;
	std::filesystem::file_time_type lastObservedModification{};
	Project project;
	Project pendingProject;
	std::mutex snapshotMutex;
	std::thread snapshotThread;
	std::atomic_bool stopSnapshotThread{ true };
	bool hasPendingProject = false;
};

static CFFGLPluginInfo PluginInfo(
	PluginFactory< StageChaseEffect >,
	"STCH",
	"StageChase Mask",
	2,
	1,
	1,
	0,
	FF_EFFECT,
	"Per-slice chase mask driven by a StageChase project",
	"StageChase"
);
}
