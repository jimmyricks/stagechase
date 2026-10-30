#include <FFGLEffect.h>
#include <FFGLParamOption.h>
#include <FFGLParamRange.h>
#include <FFGLParamTrigger.h>
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
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef STAGECHASE_EFFECT_KIND
#error STAGECHASE_EFFECT_KIND must select Outline, Bumper, or Wiper
#endif

using namespace ffglex;
using namespace ffglqs;

namespace
{
using Clock = std::chrono::steady_clock;

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
};

struct Project
{
	double canvasWidth = 1.0;
	double canvasHeight = 1.0;
	std::vector< Slice > slices;
	std::vector< Sequence > sequences;
};

struct Vertex
{
	float x;
	float y;
	float z;
	float u;
	float v;
	float effectValue;
};

struct PolygonGeometry
{
	Point center{};
	Point majorAxis{};
	Point minorAxis{};
	float minX = 0.0f;
	float minY = 0.0f;
	float majorMinimum = 0.0f;
	float majorMaximum = 0.0f;
	float minorMinimum = 0.0f;
	float minorMaximum = 0.0f;
	float width = 0.0f;
	float height = 0.0f;
	bool majorIsVertical = false;
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
	for( size_t index = 0; index < points.size(); ++index )
		remaining[ index ] = index;
	std::vector< size_t > triangles;
	triangles.reserve( ( points.size() - 2 ) * 3 );

	while( remaining.size() > 3 )
	{
		bool clipped = false;
		for( size_t index = 0; index < remaining.size(); ++index )
		{
			const size_t previous = remaining[ ( index + remaining.size() - 1 ) % remaining.size() ];
			const size_t current = remaining[ index ];
			const size_t next = remaining[ ( index + 1 ) % remaining.size() ];
			if( Cross( points[ previous ], points[ current ], points[ next ] ) * orientation <= 0.000001f )
				continue;
			bool contains = false;
			for( size_t candidate : remaining )
			{
				if( candidate != previous && candidate != current && candidate != next &&
					PointInTriangle( points[ candidate ], points[ previous ], points[ current ], points[ next ], orientation ) )
				{
					contains = true;
					break;
				}
			}
			if( contains )
				continue;
			triangles.insert( triangles.end(), { previous, current, next } );
			remaining.erase( remaining.begin() + static_cast< std::ptrdiff_t >( index ) );
			clipped = true;
			break;
		}
		if( !clipped )
			return {};
	}
	triangles.insert( triangles.end(), remaining.begin(), remaining.end() );
	return triangles;
}

static Point Add( Point a, Point b )
{
	return { a.x + b.x, a.y + b.y };
}

static Point Subtract( Point a, Point b )
{
	return { a.x - b.x, a.y - b.y };
}

static Point Multiply( Point point, float scale )
{
	return { point.x * scale, point.y * scale };
}

static float Dot( Point a, Point b )
{
	return a.x * b.x + a.y * b.y;
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
		sliceCount > 10000 || !std::isfinite( loaded.canvasWidth ) || !std::isfinite( loaded.canvasHeight ) ||
		loaded.canvasWidth <= 0.0 || loaded.canvasHeight <= 0.0 )
		return false;
	loaded.slices.reserve( sliceCount );
	for( size_t index = 0; index < sliceCount; ++index )
	{
		size_t pointCount = 0;
		if( !( stream >> pointCount ) || pointCount < 3 || pointCount > 4096 )
			return false;
		Slice slice;
		slice.points.reserve( pointCount );
		for( size_t pointIndex = 0; pointIndex < pointCount; ++pointIndex )
		{
			Point point{};
			if( !( stream >> point.x >> point.y ) || !std::isfinite( point.x ) || !std::isfinite( point.y ) )
				return false;
			slice.points.push_back( point );
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
		double stepDuration = 0.0;
		int echoes = 0;
		if( !( stream >> stepCount >> direction >> stepDuration >> scaling >> echoes ) ||
			stepCount == 0 || stepCount > 1024 || echoes < 0 || echoes > 32 )
			return false;
		Sequence sequence;
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
		in float effectValue;
		out vec2 uv;
		out float value;
		void main()
		{
			gl_Position = vec4(position, 1.0);
			uv = sourceUV;
			value = effectValue;
		}
	)";
	const char* fragmentSource = R"(
		#version 150
		in vec2 uv;
		in float value;
		out vec4 fragColor;
		void main()
		{
			fragColor = vec4(uv, value, 1.0);
		}
	)";
	auto compile = []( GLenum type, const char* source ) -> GLuint {
		GLuint shader = glCreateShader( type );
		glShaderSource( shader, 1, &source, nullptr );
		glCompileShader( shader );
		GLint compiled = GL_FALSE;
		glGetShaderiv( shader, GL_COMPILE_STATUS, &compiled );
		if( compiled == GL_TRUE )
			return shader;
		glDeleteShader( shader );
		return 0;
	};
	GLuint vertex = compile( GL_VERTEX_SHADER, vertexSource );
	GLuint fragment = compile( GL_FRAGMENT_SHADER, fragmentSource );
	if( vertex == 0 || fragment == 0 )
	{
		if( vertex != 0 ) glDeleteShader( vertex );
		if( fragment != 0 ) glDeleteShader( fragment );
		return 0;
	}
	GLuint program = glCreateProgram();
	glAttachShader( program, vertex );
	glAttachShader( program, fragment );
	glBindAttribLocation( program, 0, "position" );
	glBindAttribLocation( program, 1, "sourceUV" );
	glBindAttribLocation( program, 2, "effectValue" );
	glLinkProgram( program );
	glDeleteShader( vertex );
	glDeleteShader( fragment );
	GLint linked = GL_FALSE;
	glGetProgramiv( program, GL_LINK_STATUS, &linked );
	if( linked == GL_TRUE )
		return program;
	glDeleteProgram( program );
	return 0;
}

class MovementEffectBase : public Effect
{
public:
	MovementEffectBase() :
		maskTexture( 0 ),
		maskFramebuffer( 0 ),
		maskProgram( 0 ),
		maskVertexArray( 0 ),
		maskVertexBuffer( 0 ),
		maskWidth( 0 ),
		maskHeight( 0 )
	{
	}

	FFResult Init() override
	{
		glGenTextures( 1, &maskTexture );
		{
			Scoped2DTextureBinding texture( maskTexture );
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST );
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST );
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
			glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
		}
		glGenFramebuffers( 1, &maskFramebuffer );
		glGenVertexArrays( 1, &maskVertexArray );
		glGenBuffers( 1, &maskVertexBuffer );
		maskProgram = CreateMaskProgram();
		glBindVertexArray( maskVertexArray );
		glBindBuffer( GL_ARRAY_BUFFER, maskVertexBuffer );
		glEnableVertexAttribArray( 0 );
		glVertexAttribPointer( 0, 3, GL_FLOAT, GL_FALSE, sizeof( Vertex ),
			reinterpret_cast< const void* >( offsetof( Vertex, x ) ) );
		glEnableVertexAttribArray( 1 );
		glVertexAttribPointer( 1, 2, GL_FLOAT, GL_FALSE, sizeof( Vertex ),
			reinterpret_cast< const void* >( offsetof( Vertex, u ) ) );
		glEnableVertexAttribArray( 2 );
		glVertexAttribPointer( 2, 1, GL_FLOAT, GL_FALSE, sizeof( Vertex ),
			reinterpret_cast< const void* >( offsetof( Vertex, effectValue ) ) );
		glBindVertexArray( 0 );
		stopSnapshotThread = false;
		snapshotThread = std::thread( [ this ] { SnapshotLoop(); } );
		return maskTexture != 0 && maskFramebuffer != 0 && maskVertexArray != 0 &&
			maskVertexBuffer != 0 && maskProgram != 0 ? FF_SUCCESS : FF_FAIL;
	}

	void Clean() override
	{
		stopSnapshotThread = true;
		if( snapshotThread.joinable() )
			snapshotThread.join();
		if( maskVertexBuffer != 0 ) glDeleteBuffers( 1, &maskVertexBuffer );
		if( maskVertexArray != 0 ) glDeleteVertexArrays( 1, &maskVertexArray );
		if( maskProgram != 0 ) glDeleteProgram( maskProgram );
		if( maskFramebuffer != 0 ) glDeleteFramebuffers( 1, &maskFramebuffer );
		if( maskTexture != 0 ) glDeleteTextures( 1, &maskTexture );
		maskVertexBuffer = 0;
		maskVertexArray = 0;
		maskProgram = 0;
		maskFramebuffer = 0;
		maskTexture = 0;
	}

	FFResult Render( ProcessOpenGLStruct* input ) override
	{
		if( input == nullptr || input->numInputTextures < 1 || input->inputTextures[ 0 ] == nullptr )
			return FF_FAIL;
		if( ApplyPendingSnapshot() )
			OnProjectChanged();

		const int width = static_cast< int >( currentViewport.width );
		const int height = static_cast< int >( currentViewport.height );
		if( width <= 0 || height <= 0 )
			return FF_FAIL;
		if( width != maskWidth || height != maskHeight )
		{
			if( !EnsureMaskStorage( width, height ) )
				return FF_FAIL;
			maskWidth = width;
			maskHeight = height;
			maskDirty = true;
		}

		PrepareFrame();
		const std::vector< int > key = MaskStateKey();
		if( maskDirty || key != cachedMaskState )
		{
			vertices.clear();
			BuildMask();
			RenderMask( width, height );
			cachedMaskState = key;
			maskDirty = false;
		}

		ScopedSamplerActivation activateInput( 0 );
		Scoped2DTextureBinding inputTexture( input->inputTextures[ 0 ]->Handle );
		ScopedSamplerActivation activateMask( 1 );
		Scoped2DTextureBinding stageMask( maskTexture );
		shader.Set( "inputTexture", 0 );
		shader.Set( "stageMask", 1 );
		const FFGLTexCoords maxUV = GetMaxGLTexCoords( *input->inputTextures[ 0 ] );
		shader.Set( "maxUV", maxUV.s, maxUV.t );
		SetEffectUniforms();
		quad.Draw();
		return FF_SUCCESS;
	}

protected:
	virtual std::vector< int > MaskStateKey() = 0;
	virtual void BuildMask() = 0;
	virtual void PrepareFrame()
	{
	}
	virtual void OnProjectChanged()
	{
	}
	virtual void SetEffectUniforms()
	{
	}
	virtual float EffectValue(
		size_t sliceIndex,
		size_t stepIndex,
		size_t vertexIndex,
		const PolygonGeometry& geometry,
		float stateValue
	)
	{
		(void)sliceIndex;
		(void)stepIndex;
		(void)vertexIndex;
		(void)geometry;
		return stateValue;
	}
	virtual float SliceTag( size_t sliceIndex ) const
	{
		(void)sliceIndex;
		return 0.0f;
	}
	virtual bool UsesSliceTag() const
	{
		return false;
	}
	virtual int ScalingMode()
	{
		const auto option = GetParamOption( "Scaling" );
		return option ? static_cast< int >( option->GetRealValue() ) : 0;
	}

	const Sequence* SelectedSequence( int sequenceIndex ) const
	{
		return project.sequences.empty()
			? nullptr
			: &project.sequences[ std::min( static_cast< size_t >( std::max( sequenceIndex, 0 ) ), project.sequences.size() - 1 ) ];
	}

	void AppendPolygon(
		size_t sliceIndex,
		size_t stepIndex,
		size_t order,
		float stateValue = 0.0f,
		float progressScale = 1.0f,
		float progressOffset = 0.0f
	)
	{
		if( sliceIndex >= project.slices.size() )
			return;
		const Slice& slice = project.slices[ sliceIndex ];
		const PolygonGeometry geometry = MakeGeometry( slice );
		const int scaling = ScalingMode();
		const float sourceAspect = static_cast< float >( currentViewport.width ) /
			std::max( static_cast< float >( currentViewport.height ), 1.0f );
		const float targetAspect = geometry.width * static_cast< float >( project.canvasWidth ) /
			std::max( geometry.height * static_cast< float >( project.canvasHeight ), 0.000001f );
		const float depth = -0.9f * static_cast< float >( order ) /
			static_cast< float >( std::max( project.slices.size(), size_t( 1 ) ) );

		for( size_t vertexIndex : slice.triangles )
		{
			const Point& point = slice.points[ vertexIndex ];
			float u = 0.0f;
			float sourceTop = 0.0f;
			if( UsesSliceTag() )
			{
				u = SliceTag( sliceIndex );
				sourceTop = 1.0f - geometry.center.x;
			}
			else
			{
				u = scaling == 1 ? point.x :
					( point.x - geometry.minX ) / std::max( geometry.width, 0.000001f );
				sourceTop = scaling == 1 ? point.y :
					( point.y - geometry.minY ) / std::max( geometry.height, 0.000001f );
				if( scaling == 0 && targetAspect > 0.0f )
				{
					if( sourceAspect > targetAspect )
						u = 0.5f + ( u - 0.5f ) * targetAspect / sourceAspect;
					else
						sourceTop = 0.5f + ( sourceTop - 0.5f ) * sourceAspect / targetAspect;
				}
			}

			vertices.push_back( {
				point.x * 2.0f - 1.0f,
				1.0f - point.y * 2.0f,
				depth,
				std::clamp( u, 0.0f, 1.0f ),
				std::clamp( 1.0f - sourceTop, 0.0f, 1.0f ),
				progressOffset + EffectValue( sliceIndex, stepIndex, vertexIndex, geometry, stateValue ) * progressScale
			} );
		}
	}

private:
	PolygonGeometry MakeGeometry( const Slice& slice ) const
	{
		PolygonGeometry geometry;
		float minX = 1.0f, maxX = 0.0f, minY = 1.0f, maxY = 0.0f;
		std::vector< Point > pixels;
		pixels.reserve( slice.points.size() );
		for( const Point& point : slice.points )
		{
			minX = std::min( minX, point.x );
			maxX = std::max( maxX, point.x );
			minY = std::min( minY, point.y );
			maxY = std::max( maxY, point.y );
			pixels.push_back( {
				point.x * static_cast< float >( project.canvasWidth ),
				point.y * static_cast< float >( project.canvasHeight )
			} );
			geometry.center = Add( geometry.center, point );
		}
		if( slice.points.empty() )
			return geometry;
		geometry.center = Multiply( geometry.center, 1.0f / static_cast< float >( slice.points.size() ) );
		geometry.minX = minX;
		geometry.minY = minY;
		geometry.width = maxX - minX;
		geometry.height = maxY - minY;
		float covarianceXX = 0.0f, covarianceYY = 0.0f, covarianceXY = 0.0f;
		const Point pixelCenter = {
			geometry.center.x * static_cast< float >( project.canvasWidth ),
			geometry.center.y * static_cast< float >( project.canvasHeight )
		};
		for( Point point : pixels )
		{
			const Point centered = Subtract( point, pixelCenter );
			covarianceXX += centered.x * centered.x;
			covarianceYY += centered.y * centered.y;
			covarianceXY += centered.x * centered.y;
		}
		const float angle = 0.5f * std::atan2( 2.0f * covarianceXY, covarianceXX - covarianceYY );
		geometry.majorAxis = { std::cos( angle ), std::sin( angle ) };
		geometry.majorIsVertical = std::abs( geometry.majorAxis.y ) > std::abs( geometry.majorAxis.x );
		if( ( geometry.majorIsVertical && geometry.majorAxis.y < 0.0f ) ||
			( !geometry.majorIsVertical && geometry.majorAxis.x < 0.0f ) )
			geometry.majorAxis = Multiply( geometry.majorAxis, -1.0f );
		geometry.minorAxis = { -geometry.majorAxis.y, geometry.majorAxis.x };
		const bool minorIsVertical = !geometry.majorIsVertical;
		if( ( minorIsVertical && geometry.minorAxis.y < 0.0f ) ||
			( !minorIsVertical && geometry.minorAxis.x < 0.0f ) )
			geometry.minorAxis = Multiply( geometry.minorAxis, -1.0f );
		geometry.majorMinimum = std::numeric_limits< float >::max();
		geometry.majorMaximum = std::numeric_limits< float >::lowest();
		geometry.minorMinimum = std::numeric_limits< float >::max();
		geometry.minorMaximum = std::numeric_limits< float >::lowest();
		for( Point point : pixels )
		{
			const Point centered = Subtract( point, pixelCenter );
			const float major = Dot( centered, geometry.majorAxis );
			const float minor = Dot( centered, geometry.minorAxis );
			geometry.majorMinimum = std::min( geometry.majorMinimum, major );
			geometry.majorMaximum = std::max( geometry.majorMaximum, major );
			geometry.minorMinimum = std::min( geometry.minorMinimum, minor );
			geometry.minorMaximum = std::max( geometry.minorMaximum, minor );
		}
		return geometry;
	}

	bool EnsureMaskStorage( int width, int height )
	{
		GLint previousFramebuffer = 0;
		glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer );
		{
			Scoped2DTextureBinding texture( maskTexture );
			glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA32F, width, height, 0, GL_RGBA, GL_FLOAT, nullptr );
		}
		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, maskFramebuffer );
		glFramebufferTexture2D( GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, maskTexture, 0 );
		const bool complete = glCheckFramebufferStatus( GL_DRAW_FRAMEBUFFER ) == GL_FRAMEBUFFER_COMPLETE;
		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, static_cast< GLuint >( previousFramebuffer ) );
		return complete;
	}

	void RenderMask( int width, int height )
	{
		GLint previousFramebuffer = 0;
		GLint previousViewport[ 4 ]{};
		GLint previousProgram = 0;
		GLint previousVertexArray = 0;
		GLint previousArrayBuffer = 0;
		GLfloat clearColor[ 4 ]{};
		GLboolean colorMask[ 4 ]{};
		const bool blendWasEnabled = glIsEnabled( GL_BLEND ) == GL_TRUE;
		const bool depthWasEnabled = glIsEnabled( GL_DEPTH_TEST ) == GL_TRUE;
		const bool scissorWasEnabled = glIsEnabled( GL_SCISSOR_TEST ) == GL_TRUE;
		const bool cullWasEnabled = glIsEnabled( GL_CULL_FACE ) == GL_TRUE;
		const bool stencilWasEnabled = glIsEnabled( GL_STENCIL_TEST ) == GL_TRUE;
		glGetIntegerv( GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer );
		glGetIntegerv( GL_VIEWPORT, previousViewport );
		glGetIntegerv( GL_CURRENT_PROGRAM, &previousProgram );
		glGetIntegerv( GL_VERTEX_ARRAY_BINDING, &previousVertexArray );
		glGetIntegerv( GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer );
		glGetFloatv( GL_COLOR_CLEAR_VALUE, clearColor );
		glGetBooleanv( GL_COLOR_WRITEMASK, colorMask );
		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, maskFramebuffer );
		glViewport( 0, 0, width, height );
		glDisable( GL_BLEND );
		glDisable( GL_DEPTH_TEST );
		glDisable( GL_SCISSOR_TEST );
		glDisable( GL_CULL_FACE );
		glDisable( GL_STENCIL_TEST );
		glColorMask( GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE );
		glClearColor( 0.0f, 0.0f, 0.0f, 0.0f );
		glClear( GL_COLOR_BUFFER_BIT );
		if( !vertices.empty() )
		{
			glUseProgram( maskProgram );
			glBindVertexArray( maskVertexArray );
			glBindBuffer( GL_ARRAY_BUFFER, maskVertexBuffer );
			glBufferData( GL_ARRAY_BUFFER, vertices.size() * sizeof( Vertex ), vertices.data(), GL_STREAM_DRAW );
			glDrawArrays( GL_TRIANGLES, 0, static_cast< GLsizei >( vertices.size() ) );
		}
		glBindFramebuffer( GL_DRAW_FRAMEBUFFER, static_cast< GLuint >( previousFramebuffer ) );
		glViewport( previousViewport[ 0 ], previousViewport[ 1 ], previousViewport[ 2 ], previousViewport[ 3 ] );
		glUseProgram( static_cast< GLuint >( previousProgram ) );
		glBindVertexArray( static_cast< GLuint >( previousVertexArray ) );
		glBindBuffer( GL_ARRAY_BUFFER, static_cast< GLuint >( previousArrayBuffer ) );
		glColorMask( colorMask[ 0 ], colorMask[ 1 ], colorMask[ 2 ], colorMask[ 3 ] );
		glClearColor( clearColor[ 0 ], clearColor[ 1 ], clearColor[ 2 ], clearColor[ 3 ] );
		if( blendWasEnabled ) glEnable( GL_BLEND ); else glDisable( GL_BLEND );
		if( depthWasEnabled ) glEnable( GL_DEPTH_TEST ); else glDisable( GL_DEPTH_TEST );
		if( scissorWasEnabled ) glEnable( GL_SCISSOR_TEST ); else glDisable( GL_SCISSOR_TEST );
		if( cullWasEnabled ) glEnable( GL_CULL_FACE ); else glDisable( GL_CULL_FACE );
		if( stencilWasEnabled ) glEnable( GL_STENCIL_TEST ); else glDisable( GL_STENCIL_TEST );
	}

	void SnapshotLoop()
	{
		const auto path = SnapshotPath();
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

	bool ApplyPendingSnapshot()
	{
		std::lock_guard< std::mutex > lock( snapshotMutex );
		if( !hasPendingProject )
			return false;
		project = std::move( pendingProject );
		hasPendingProject = false;
		++projectRevision;
		maskDirty = true;
		return true;
	}

protected:
	Project project;
	std::vector< Vertex > vertices;
	int projectRevision = 0;
	bool maskDirty = true;

private:
	GLuint maskTexture;
	GLuint maskFramebuffer;
	GLuint maskProgram;
	GLuint maskVertexArray;
	GLuint maskVertexBuffer;
	int maskWidth;
	int maskHeight;
	std::vector< int > cachedMaskState;
	std::filesystem::file_time_type lastObservedModification{};
	Project pendingProject;
	std::mutex snapshotMutex;
	std::thread snapshotThread;
	std::atomic_bool stopSnapshotThread{ true };
	bool hasPendingProject = false;
};

class OutlineEffect final : public MovementEffectBase
{
	enum Parameters
	{
		ColorRedParameter,
		ColorGreenParameter,
		ColorBlueParameter,
		WidthParameter,
		FeatherParameter,
		AnimateParameter,
		PhaseParameter,
		FanParameter,
		RandomiseParameter,
		LengthParameter,
		CountParameter,
		FlipParameter,
		AlternateParameter,
		SpeedParameter
	};

public:
	OutlineEffect()
	{
		AddRGBColorParam( "Color" );
		AddParam( ParamRange::Create( "Width", 8.0f, { 1.0f, 64.0f } ) );
		AddParam( ParamRange::Create( "Feather", 0.0f, { 0.0f, 32.0f } ) );
		AddParam( Param::Create( "Animate", FF_TYPE_BOOLEAN, 0.0f ) );
		AddParam( ParamRange::Create( "Phase", 0.0f, { 0.0f, 1.0f } ) );
		AddParam( ParamRange::Create( "Fan", 0.0f, { 0.0f, 1.0f } ) );
		AddParam( ParamRange::Create( "Randomise", 0.0f, { 0.0f, 1.0f } ) );
		AddParam( ParamRange::Create( "Length", 0.25f, { 0.01f, 1.0f } ) );
		AddParam( ParamRange::CreateInteger( "Count", 1, { 1.0f, 32.0f } ) );
		AddParam( Param::Create( "FlipDirection", FF_TYPE_BOOLEAN, 0.0f ) );
		AddParam( Param::Create( "OddEven", FF_TYPE_BOOLEAN, 0.0f ) );
		AddParam( ParamRange::Create( "Speed", 0.15f, { 0.0f, 2.0f } ) );
		SetFragmentShader( R"(
			uniform sampler2D stageMask;
			uniform float SliceCount;

			float edgeAt(vec2 sampleUV, vec4 center)
			{
				if (sampleUV.x < 0.0 || sampleUV.x > 1.0 || sampleUV.y < 0.0 || sampleUV.y > 1.0)
					return 1.0;
				vec4 neighbor = texture(stageMask, sampleUV);
				float sameSlice = 1.0 - step(0.0000001, abs(center.r - neighbor.r));
				return max(1.0 - neighbor.a * sameSlice, 1.0 - neighbor.a);
			}

			void main()
			{
				vec2 uv = gl_FragCoord.xy / resolution;
				vec4 mask = texture(stageMask, uv);
				if (mask.a < 0.5)
				{
					fragColor = vec4(0.0);
					return;
				}

				float edgeDistance = Width + 1.0;
				for (int ring = 4; ring >= 1; --ring)
				{
					float radius = Width * float(ring) * 0.25;
					bool boundaryFound = false;
					for (int direction = 0; direction < 8; ++direction)
					{
						float angle = 6.2831853 * float(direction) / 8.0;
						vec2 offset = vec2(cos(angle), sin(angle)) * radius / resolution;
						if (edgeAt(uv + offset, mask) > 0.5)
						{
							boundaryFound = true;
							break;
						}
					}
					if (!boundaryFound)
						break;
					edgeDistance = radius;
				}
				float stroke = edgeDistance <= Width ? 1.0 : 0.0;
				if (Feather > 0.0)
					stroke *= 1.0 - smoothstep(max(Width - Feather, 0.0), Width, edgeDistance);

				float sliceIndex = floor(mask.r * SliceCount);
				float oddSlice = mod(sliceIndex, 2.0);
				float reverse = (FlipDirection != (OddEven && oddSlice > 0.5)) ? 1.0 : 0.0;
				float progress = fract(atan(uv.y - mask.b, uv.x - mask.g) / 6.2831853 + 1.0);
				progress = reverse > 0.5 ? 1.0 - progress : progress;
				float randomOffset = fract(sin(sliceIndex * 12.9898) * 43758.5453) * Randomise;
				float movingPhase = fract(Phase + time * Speed);
				float position = fract(progress * Count + Fan * sliceIndex + randomOffset - movingPhase);
				if (Animate)
					stroke *= step(position, Length);
				fragColor = vec4(Color * stroke, stroke);
			}
		)" );
	}

protected:
	std::vector< int > MaskStateKey() override
	{
		return { projectRevision };
	}

	void BuildMask() override
	{
		const size_t count = project.slices.size();
		for( size_t sliceIndex = 0; sliceIndex < count; ++sliceIndex )
			AppendPolygon( sliceIndex, 0, sliceIndex );
	}

	void SetEffectUniforms() override
	{
		shader.Set( "SliceCount", static_cast< float >( std::max( project.slices.size(), size_t( 1 ) ) ) );
	}

	float EffectValue( size_t, size_t, size_t, const PolygonGeometry& geometry, float ) override
	{
		return 1.0f - geometry.center.y;
	}

	float SliceTag( size_t sliceIndex ) const override
	{
		return static_cast< float >( sliceIndex + 1 ) /
			static_cast< float >( std::max( project.slices.size() + 1, size_t( 2 ) ) );
	}

	bool UsesSliceTag() const override
	{
		return true;
	}

	int ScalingMode() override
	{
		return 0;
	}
};

class BumperEffect final : public MovementEffectBase
{
	enum Parameters
	{
		SequenceParameter,
		ScalingParameter,
		NextParameter,
		PreviousParameter,
		BlastParameter,
		BlastSpeedParameter,
		AutoResetParameter,
		ResetDelayParameter,
		FadeSpeedParameter
	};

	struct Pulse
	{
		size_t sliceIndex;
		float startTime;
	};

public:
	BumperEffect() :
		selectedStep( 0 ),
		sequenceIndex( -1 ),
		maskRevision( 0 ),
		lastActivity( 0.0f ),
		lastBlast( 0.0f ),
		blastActive( false ),
		resetDone( false ),
		started( false )
	{
		AddParam( ParamRange::CreateInteger( "Sequence", 0, { 0.0f, 1023.0f } ) );
		AddParam( ParamOption::Create( "Scaling", { { "Fill", 0.0f }, { "Mask", 1.0f } } ) );
		AddParam( ParamTrigger::Create( "Next" ) );
		AddParam( ParamTrigger::Create( "Previous" ) );
		AddParam( ParamTrigger::Create( "Blast" ) );
		AddParam( ParamRange::Create( "BlastSpeed", 8.0f, { 1.0f, 30.0f } ) );
		AddParam( Param::Create( "AutoReset", FF_TYPE_BOOLEAN, 1.0f ) );
		AddParam( ParamRange::Create( "ResetDelay", 1.0f, { 0.0f, 10.0f } ) );
		AddParam( ParamRange::Create( "FadeSpeed", 0.35f, { 0.05f, 5.0f } ) );
		SetFragmentShader( R"(
			uniform sampler2D stageMask;
			uniform vec2 maxUV;
			void main()
			{
				vec4 mask = texture(stageMask, gl_FragCoord.xy / resolution);
				vec4 color = texture(inputTexture, mask.rg * maxUV);
				float fade = clamp(1.0 - max(time - mask.b, 0.0) / max(FadeSpeed, 0.001), 0.0, 1.0);
				float visible = mask.a * fade;
				fragColor = vec4(color.rgb * visible, color.a * visible);
			}
		)" );
	}

protected:
	std::vector< int > MaskStateKey() override
	{
		return { sequenceIndex, ScalingMode(), maskRevision, projectRevision };
	}

	void BuildMask() override
	{
		size_t order = 0;
		for( const Pulse& pulse : pulses )
			AppendPolygon( pulse.sliceIndex, 0, order++, pulse.startTime );
	}

	void OnProjectChanged() override
	{
		pulses.clear();
		selectedStep = 0;
		sequenceIndex = -1;
		started = false;
		blastActive = false;
		resetDone = false;
		lastActivity = timeNow;
		++maskRevision;
	}

	void PrepareFrame() override
	{
		const int requestedSequence = std::clamp( static_cast< int >( GetFloatParameter( SequenceParameter ) ), 0, 1023 );
		bool changed = false;
		if( !started || requestedSequence != sequenceIndex )
		{
			sequenceIndex = requestedSequence;
			selectedStep = 0;
			pulses.clear();
			blastActive = false;
			resetDone = false;
			lastActivity = timeNow;
			started = true;
			AddPulse( selectedStep, false );
			changed = true;
		}

		const Sequence* sequence = SelectedSequence( sequenceIndex );
		const size_t count = sequence == nullptr || sequence->steps.empty() ? 1 : sequence->steps.size();
		if( GetFloatParameter( NextParameter ) > 0.5f )
		{
			selectedStep = ( selectedStep + 1 ) % count;
			AddPulse( selectedStep, true );
			changed = true;
		}
		if( GetFloatParameter( PreviousParameter ) > 0.5f )
		{
			selectedStep = ( selectedStep + count - 1 ) % count;
			AddPulse( selectedStep, true );
			changed = true;
		}
		if( GetFloatParameter( BlastParameter ) > 0.5f )
		{
			blastActive = !blastActive;
			lastActivity = timeNow;
			resetDone = false;
			lastBlast = timeNow;
			changed = true;
		}
		if( blastActive )
		{
			const float interval = 1.0f / std::max( GetFloatParameter( BlastSpeedParameter ), 1.0f );
			for( int countThisFrame = 0; countThisFrame < 32 && timeNow - lastBlast >= interval; ++countThisFrame )
			{
				selectedStep = ( selectedStep + 1 ) % count;
				lastBlast += interval;
				AddPulse( selectedStep, true );
				changed = true;
			}
		}
		if( GetFloatParameter( AutoResetParameter ) > 0.5f && !resetDone &&
			timeNow - lastActivity >= GetFloatParameter( ResetDelayParameter ) )
		{
			selectedStep = 0;
			blastActive = false;
			AddPulse( selectedStep, false );
			resetDone = true;
			changed = true;
		}

		const size_t pulseCount = pulses.size();
		pulses.erase(
			std::remove_if( pulses.begin(), pulses.end(), [ this ]( const Pulse& pulse ) {
				return timeNow - pulse.startTime >= GetFloatParameter( FadeSpeedParameter );
			}),
			pulses.end()
		);
		if( pulseCount != pulses.size() )
			changed = true;
		if( changed )
			++maskRevision;
	}

private:
	void AddPulse( size_t stepIndex, bool countsAsActivity )
	{
		const Sequence* sequence = SelectedSequence( sequenceIndex );
		if( sequence != nullptr && stepIndex < sequence->steps.size() )
		{
			for( size_t sliceIndex : sequence->steps[ stepIndex ].slices )
			{
				auto pulse = std::find_if( pulses.begin(), pulses.end(), [ sliceIndex ]( const Pulse& active ) {
					return active.sliceIndex == sliceIndex;
				} );
				if( pulse == pulses.end() )
					pulses.push_back( { sliceIndex, timeNow } );
				else
					pulse->startTime = timeNow;
			}
		}
		if( countsAsActivity )
		{
			lastActivity = timeNow;
			resetDone = false;
		}
	}

	size_t selectedStep;
	int sequenceIndex;
	int maskRevision;
	float lastActivity;
	float lastBlast;
	bool blastActive;
	bool resetDone;
	bool started;
	std::vector< Pulse > pulses;
};

class WiperEffect final : public MovementEffectBase
{
	enum Parameters
	{
		SequenceParameter,
		StepParameter,
		ScalingParameter,
		LengthParameter,
		OverlapParameter,
		LoopsParameter,
		FlipParameter,
		AlternateParameter,
		SwapParameter
	};

public:
	WiperEffect() :
		sequenceIndex( 0 ),
		stepIndex( 0 ),
		phase( 0.0f )
	{
		AddParam( ParamRange::CreateInteger( "Sequence", 0, { 0.0f, 1023.0f } ) );
		AddParam( ParamRange::Create( "Step", 0.08f, { 0.0f, 1.0f } ) );
		AddParam( ParamOption::Create( "Scaling", { { "Fill", 0.0f }, { "Mask", 1.0f } } ) );
		AddParam( ParamRange::Create( "Length", 0.2f, { 0.01f, 1.0f } ) );
		AddParam( ParamRange::Create( "Overlap", 0.0f, { 0.0f, 0.95f } ) );
		AddParam( ParamRange::CreateInteger( "Loops", 1, { 1.0f, 16.0f } ) );
		AddParam( Param::Create( "FlipDirection", FF_TYPE_BOOLEAN, 0.0f ) );
		AddParam( Param::Create( "OddEven", FF_TYPE_BOOLEAN, 0.0f ) );
		AddParam( Param::Create( "SwapDirections", FF_TYPE_BOOLEAN, 0.0f ) );
		SetFragmentShader( R"(
			uniform sampler2D stageMask;
			uniform vec2 maxUV;
			uniform float Phase;
			void main()
			{
				vec4 mask = texture(stageMask, gl_FragCoord.xy / resolution);
				vec4 color = texture(inputTexture, mask.rg * maxUV);
				float edge = max(Length * 0.5, 0.002);
				float visible = smoothstep(mask.b - edge, mask.b + edge, Phase) * mask.a;
				fragColor = vec4(color.rgb * visible, color.a * visible);
			}
		)" );
	}

protected:
	std::vector< int > MaskStateKey() override
	{
		const int overlap = static_cast< int >( GetFloatParameter( OverlapParameter ) * 1000.0f );
		return {
			sequenceIndex,
			static_cast< int >( stepIndex ),
			ScalingMode(),
			GetFloatParameter( FlipParameter ) > 0.5f,
			GetFloatParameter( AlternateParameter ) > 0.5f,
			GetFloatParameter( SwapParameter ) > 0.5f,
			overlap,
			projectRevision
		};
	}

	void PrepareFrame() override
	{
		sequenceIndex = std::clamp( static_cast< int >( GetFloatParameter( SequenceParameter ) ), 0, 1023 );
		const Sequence* sequence = SelectedSequence( sequenceIndex );
		const size_t count = sequence == nullptr || sequence->steps.empty() ? 1 : sequence->steps.size();
		const int loops = std::clamp( static_cast< int >( GetFloatParameter( LoopsParameter ) ), 1, 16 );
		const float position = std::clamp( GetFloatParameter( StepParameter ), 0.0f, 1.0f ) *
			static_cast< float >( loops ) * static_cast< float >( count );
		stepIndex = static_cast< size_t >( position ) % count;
		phase = std::fmod( position, 1.0f );
	}

	void BuildMask() override
	{
		const Sequence* sequence = SelectedSequence( sequenceIndex );
		if( sequence == nullptr || sequence->steps.empty() )
			return;
		const float overlap = std::clamp( GetFloatParameter( OverlapParameter ), 0.0f, 0.95f );
		std::vector< bool > seen( project.slices.size(), false );
		size_t order = 0;
		for( size_t sliceIndex : sequence->steps[ stepIndex ].slices )
		{
			if( sliceIndex >= seen.size() || seen[ sliceIndex ] )
				continue;
			seen[ sliceIndex ] = true;
			AppendPolygon( sliceIndex, stepIndex, order++ );
		}
		if( overlap <= 0.0f || sequence->steps.size() < 2 )
			return;
		const size_t nextStep = ( stepIndex + 1 ) % sequence->steps.size();
		for( size_t sliceIndex : sequence->steps[ nextStep ].slices )
		{
			if( sliceIndex >= seen.size() || seen[ sliceIndex ] )
				continue;
			seen[ sliceIndex ] = true;
			AppendPolygon( sliceIndex, nextStep, order++, 0.0f, overlap, 1.0f - overlap );
		}
	}

	void SetEffectUniforms() override
	{
		shader.Set( "Phase", phase );
	}

	float EffectValue(
		size_t sliceIndex,
		size_t step,
		size_t vertexIndex,
		const PolygonGeometry& geometry,
		float
	) override
	{
		const bool majorVertical = geometry.majorIsVertical;
		bool vertical = majorVertical;
		if( GetFloatParameter( SwapParameter ) > 0.5f )
			vertical = !vertical;
		Point axis = vertical == majorVertical ? geometry.majorAxis : geometry.minorAxis;
		const Point& point = project.slices[ sliceIndex ].points[ vertexIndex ];
		const Point pixelPoint = {
			point.x * static_cast< float >( project.canvasWidth ),
			point.y * static_cast< float >( project.canvasHeight )
		};
		const Point center = {
			geometry.center.x * static_cast< float >( project.canvasWidth ),
			geometry.center.y * static_cast< float >( project.canvasHeight )
		};
		const float minimum = vertical == majorVertical ? geometry.majorMinimum : geometry.minorMinimum;
		const float maximum = vertical == majorVertical ? geometry.majorMaximum : geometry.minorMaximum;
		const float extent = std::max( maximum - minimum, 0.000001f );
		float coordinate = ( Dot( Subtract( pixelPoint, center ), axis ) - minimum ) / extent;
		if( vertical )
			coordinate = 1.0f - coordinate;
		else
		{
			const float centerPosition = center.x / static_cast< float >( project.canvasWidth );
			if( std::abs( centerPosition - 0.5f ) < 0.01f )
				coordinate = 2.0f * std::abs( coordinate - 0.5f );
			else if( centerPosition < 0.5f )
				coordinate = 1.0f - coordinate;
		}
		const bool reverse = ( GetFloatParameter( FlipParameter ) > 0.5f ) !=
			( GetFloatParameter( AlternateParameter ) > 0.5f && step % 2 == 1 );
		return reverse ? 1.0f - coordinate : coordinate;
	}

private:
	int sequenceIndex;
	size_t stepIndex;
	float phase;
};

#if STAGECHASE_EFFECT_KIND == 1
static CFFGLPluginInfo PluginInfo(
	PluginFactory< OutlineEffect >,
	"STOL",
	"Chase Outline",
	2, 1, 1, 0, FF_EFFECT,
	"Animated outlines clipped to StageChase slices",
	"StageChase"
);
#elif STAGECHASE_EFFECT_KIND == 2
static CFFGLPluginInfo PluginInfo(
	PluginFactory< BumperEffect >,
	"STBU",
	"Chase Bumper",
	2, 1, 1, 0, FF_EFFECT,
	"Manually triggered sequence steps for StageChase",
	"StageChase"
);
#elif STAGECHASE_EFFECT_KIND == 3
static CFFGLPluginInfo PluginInfo(
	PluginFactory< WiperEffect >,
	"STWI",
	"Chase Wiper",
	2, 1, 1, 0, FF_EFFECT,
	"Gradient wipes driven by StageChase sequences",
	"StageChase"
);
#else
#error STAGECHASE_EFFECT_KIND must be 1, 2, or 3
#endif
}
